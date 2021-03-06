//
//  TSAxolotlRatchet.m
//  TextSecureiOS
//
//  Created by Christine Corbett Moran on 1/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.
//

#import "TSAxolotlRatchet.hh"

#import "TSMessage.h"
#import "TSThread.h"
#import "TSContact.h"
#import "NSData+Base64.h"
#import "TSSubmitMessageRequest.h"
#import "TSMessagesManager.h"
#import "TSKeyManager.h"
#import "Cryptography.h"
#import "TSMessage.h"
#import "TSMessagesDatabase.h"
#import "TSUserKeysDatabase.h"
#import "TSThread.h"
#import "TSMessageSignal.hh"
#import "TSPushMessageContent.hh"
#import "TSWhisperMessage.hh"
#import "TSEncryptedWhisperMessage.hh"
#import "TSPreKeyWhisperMessage.hh"
#import "TSRecipientPrekeyRequest.h"
#import "TSWhisperMessageKeys.h"
#import "TSHKDF.h"
#import "RKCK.h"
#import "TSContact.h"

@implementation TSAxolotlRatchet

-(id) initForThread:(TSThread*)threadForRatchet{
    if(self = [super init]) {
        self.thread = threadForRatchet;
    }
    return self;
}

#pragma mark public methods

+(void)sendMessage:(TSMessage*)message onThread:(TSThread*)thread{
    
    // Message should be added to the database
    
    [TSMessagesDatabase storeMessage:message fromThread:thread withCompletionBlock:^(BOOL success) {
        if (success) {
            
        }else{
            // Notify the user that the message couldn't be stored
        }
    }];
    
    // For a given thread, the Axolotl Ratchet should find out what's the current messaging state to send the message.
    
#warning Assuming prekey communication only for now.
    
    TSWhisperMessageType messageType = TSPreKeyWhisperMessageType;
    
    TSAxolotlRatchet *ratchet = [[TSAxolotlRatchet alloc] initForThread:thread];
    
    switch (messageType) {
            
        case TSPreKeyWhisperMessageType:{
            // get a contact's prekey
            TSContact* contact = [[TSContact alloc] initWithRegisteredID:message.recipientId];
            TSThread* thread = [TSThread threadWithContacts:@[[[TSContact alloc] initWithRegisteredID:message.recipientId]]];
            [[TSNetworkManager sharedManager] queueAuthenticatedRequest:[[TSRecipientPrekeyRequest alloc] initWithRecipient:contact] success:^(AFHTTPRequestOperation *operation, id responseObject) {
                switch (operation.response.statusCode) {
                    case 200:{
                        NSLog(@"Prekey fetched :) ");
                        
                        // Extracting the recipients keying material from server payload
                        
                        NSData* theirIdentityKey = [NSData dataFromBase64String:[responseObject objectForKey:@"identityKey"]];
                        NSData* theirEphemeralKey = [NSData dataFromBase64String:[responseObject objectForKey:@"publicKey"]];
                        NSNumber* theirPrekeyId = [responseObject objectForKey:@"keyId"];
                        
                        // remove the leading "0x05" byte as per protocol specs
                        if (theirEphemeralKey.length == 33) {
                            theirEphemeralKey = [theirEphemeralKey subdataWithRange:NSMakeRange(1, 32)];
                        }
                        
                        // remove the leading "0x05" byte as per protocol specs
                        if (theirIdentityKey.length == 33) {
                            theirIdentityKey = [theirIdentityKey subdataWithRange:NSMakeRange(1, 32)];
                        }
                        
                        // Retreiving my keying material to construct message
                        
                        TSECKeyPair *myCurrentEphemeral = [ratchet ratchetSetupFirstSender:theirIdentityKey theirEphemeralKey:theirEphemeralKey];
                        [ratchet nextMessageKeysOnChain:TSSendingChain withCompletion:^(TSWhisperMessageKeys *messageKeys) {
                            NSData *encryptedMessage = [ratchet encryptTSMessage:message withKeys:messageKeys withCTR:[NSNumber numberWithInt:0]];
                            [TSMessagesDatabase getEphemeralOfSendingChain:thread withCompletionBlock:^(TSECKeyPair *nextEphemeral ) {
                                NSData* encodedPreKeyWhisperMessage = [TSPreKeyWhisperMessage constructFirstMessage:encryptedMessage theirPrekeyId:theirPrekeyId myCurrentEphemeral:myCurrentEphemeral myNextEphemeral:nextEphemeral];
                                [[TSMessagesManager sharedManager] submitMessageTo:message.recipientId message:[encodedPreKeyWhisperMessage base64EncodedString] ofType:messageType];
                            }];
                        }];
                        // nil
                        break;
                    }
                    default:
                        DLog(@"error sending message");
#warning Add error handling if not able to get contacts prekey
                        break;
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
#warning right now it is not succesfully processing returned response, but is giving 200
                
            }];
            
            break;
        }
        case TSEncryptedWhisperMessageType: {
            // unsupported
            break;
        }
        case TSUnencryptedWhisperMessageType: {
            NSString *serializedMessage= [[TSPushMessageContent serializedPushMessageContent:message] base64EncodedStringWithOptions:0];
            [[TSMessagesManager sharedManager] submitMessageTo:message.recipientId message:serializedMessage ofType:messageType];
            break;
        }
        default:
            break;
    }
}

+(void)receiveMessage:(NSData*)data withCompletion:(decryptMessageCompletion)block{
    
    NSData* decryptedPayload = [Cryptography decryptAppleMessagePayload:data withSignalingKey:[TSKeyManager getSignalingKeyToken]];
    TSMessageSignal *messageSignal = [[TSMessageSignal alloc] initWithData:decryptedPayload];
    
    TSAxolotlRatchet *ratchet = [[TSAxolotlRatchet alloc] initForThread:[TSThread threadWithContacts: @[[[TSContact alloc] initWithRegisteredID:messageSignal.source]]]];
    
    TSMessage* message;
    
    switch (messageSignal.contentType) {
            
        case TSPreKeyWhisperMessageType: {
            
            TSPreKeyWhisperMessage* preKeyMessage = (TSPreKeyWhisperMessage*)messageSignal.message;
            TSEncryptedWhisperMessage* whisperMessage = (TSEncryptedWhisperMessage*)preKeyMessage.message;
            
            [ratchet ratchetSetupFirstReceiver:preKeyMessage.identityKey theirEphemeralKey:preKeyMessage.baseKey withMyPrekeyId:preKeyMessage.preKeyId withCompletion:^(BOOL success) {
                [ratchet updateChainsOnReceivedMessage:preKeyMessage.baseKey withCompletion:^(TSECKeyPair *decryptionKey) {
                    [ratchet nextMessageKeysOnChain:TSReceivingChain withCompletion:^(TSWhisperMessageKeys *messageKeys) {
                        NSData* tsMessageDecryption = [Cryptography decryptCTRMode:whisperMessage.message withKeys:messageKeys withCounter:whisperMessage.counter];
                        
                        TSMessage *message = [TSMessage messageWithContent:[[NSString alloc] initWithData:tsMessageDecryption encoding:NSASCIIStringEncoding]
                                                                    sender:messageSignal.source
                                                                 recipient:[TSKeyManager getUsernameToken]
                                                                      date:messageSignal.timestamp];
                        
                        NSLog(@"You have a new message from %@: %@",message.senderId, message.content);
                    }];
                    
                    block(message);
                }];
                
            }];
            
            break;
        }
            
        case TSEncryptedWhisperMessageType: {
            TSEncryptedWhisperMessage* whisperMessage = (TSEncryptedWhisperMessage*)messageSignal.message;
            
            [ratchet updateChainsOnReceivedMessage:whisperMessage.ephemeralKey withCompletion:^(TSECKeyPair *decryptionKey) {
                [ratchet nextMessageKeysOnChain:TSReceivingChain withCompletion:^(TSWhisperMessageKeys *messageKeys) {
                    NSData* tsMessageDecryption = [Cryptography decryptCTRMode:whisperMessage.message withKeys:messageKeys withCounter:whisperMessage.counter];
                    
                    TSMessage *message = [TSMessage messageWithContent:[[NSString alloc] initWithData:tsMessageDecryption encoding:NSASCIIStringEncoding]
                                                                sender:messageSignal.source
                                                             recipient:[TSKeyManager getUsernameToken]
                                                                  date:messageSignal.timestamp];
                    
                    NSLog(@"You have a new message from %@: %@",message.senderId, message.content);
                    block(message);
                }];
            }];
            break;
        }
            
        case TSUnencryptedWhisperMessageType: {
            TSPushMessageContent* messageContent = [[TSPushMessageContent alloc] initWithData:messageSignal.message.message];
            message = [messageSignal getTSMessage:messageContent];
            break;
        }
            
        default:
            // TODO: Missing error handling here ? Otherwise we're storing a nil message
            @throw [NSException exceptionWithName:@"Invalid state" reason:@"This should not happen" userInfo:nil];
            break;
    }
    
    [TSMessagesDatabase storeMessage:message fromThread:[TSThread threadWithContacts: @[[[TSContact alloc]  initWithRegisteredID:message.senderId]]]withCompletionBlock:nil];
}


#pragma mark private methods
-(TSECKeyPair*) ratchetSetupFirstSender:(NSData*)theirIdentity theirEphemeralKey:(NSData*)theirEphemeral {
    
    /* after this we will have the CK of the Sending Chain */
    
    NSError *error = nil;
    TSECKeyPair *ourIdentityKey = [TSUserKeysDatabase getIdentityKeyWithError:&error];
    
    if (error) {
        // Handle this
    }
    
    TSECKeyPair *ourEphemeralKey = [TSECKeyPair keyPairGenerateWithPreKeyId:0]; // We generate a new key pair unique to this thread.
    
    NSData* ourMasterKey = [self masterKeyAlice:ourIdentityKey ourEphemeral:ourEphemeralKey   theirIdentityPublicKey:theirIdentity theirEphemeralPublicKey:theirEphemeral];
    
    RKCK* receivingChain = [self initialRootKey:ourMasterKey];
    
    TSECKeyPair* sendingKey = [TSECKeyPair keyPairGenerateWithPreKeyId:0];
    RKCK* sendingChain = [receivingChain createChainWithNewEphemeral:sendingKey fromTheirProvideEphemeral:theirEphemeral]; // This will be used
    
    [receivingChain saveReceivingChainOnThread:self.thread withTheirEphemeral:theirEphemeral withCompletionHandler:^(BOOL success) {
        if (success) {
            [sendingChain saveSendingChainOnThread:self.thread withMyNewEphemeral:sendingKey withCompletionHandler:^(BOOL success) {
                if (success) {
                    // TO DO : Deal with error handeling
                }
            }];
        }
    }];
    
    return ourEphemeralKey;
    
}

-(void)updateChainsOnReceivedMessage:(NSData*)theirNewEphemeral withCompletion:(getNewReceiveDecryptKey)block {
    [RKCK currentSendingChain:self.thread withCompletionHandler:^(RKCK *keypair) {
        RKCK *currentSendingChain = keypair;
        
        RKCK *newReceivingChain = [currentSendingChain createChainWithNewEphemeral:currentSendingChain.ephemeral fromTheirProvideEphemeral:theirNewEphemeral];
        /// generate new sending chain with their new Ephemeral, my new epemeral
        // encyrpt messages with this and send it off
        TSECKeyPair* newSendingKey = [TSECKeyPair keyPairGenerateWithPreKeyId:0];
        RKCK *newSendingChain = [newReceivingChain createChainWithNewEphemeral:newSendingKey fromTheirProvideEphemeral:theirNewEphemeral];
        [newReceivingChain saveReceivingChainOnThread:self.thread withTheirEphemeral:theirNewEphemeral withCompletionHandler:^(BOOL success) {
            [newSendingChain saveSendingChainOnThread:self.thread withMyNewEphemeral:newSendingKey withCompletionHandler:^(BOOL success) {
                // Deal with error handeling
                block(newSendingKey);
            }];
            
        }];
    }];
}


-(void) ratchetSetupFirstReceiver:(NSData*)theirIdentityKey theirEphemeralKey:(NSData*)theirEphemeralKey withMyPrekeyId:(NSNumber*)preKeyId withCompletion:(performSaveOnChainCompletionBlock) block{
    /* after this we will have the CK of the Receiving Chain */
    TSECKeyPair *ourEphemeralKey = [TSUserKeysDatabase getPreKeyWithId:[preKeyId unsignedLongValue] error:nil];
    TSECKeyPair *ourIdentityKey =  [TSUserKeysDatabase getIdentityKeyWithError:nil];
    
    NSData* ourMasterKey = [self masterKeyBob:ourIdentityKey ourEphemeral:ourEphemeralKey theirIdentityPublicKey:theirIdentityKey theirEphemeralPublicKey:theirEphemeralKey];
    RKCK* sendingChain = [self initialRootKey:ourMasterKey];
    [sendingChain saveSendingChainOnThread:self.thread withMyNewEphemeral:ourEphemeralKey withCompletionHandler:^(BOOL success) {
        if (success) {
            block(TRUE);
        }
    }];
}


-(NSData*) encryptTSMessage:(TSMessage*)message  withKeys:(TSWhisperMessageKeys *)messageKeys withCTR:(NSNumber*)counter{
    return [Cryptography encryptCTRMode:[message.content dataUsingEncoding:NSASCIIStringEncoding] withKeys:messageKeys withCounter:counter];
}

#pragma mark helper methods

-(NSData*)masterKeyAlice:(TSECKeyPair*)ourIdentityKeyPair ourEphemeral:(TSECKeyPair*)ourEphemeralKeyPair theirIdentityPublicKey:(NSData*)theirIdentityPublicKey theirEphemeralPublicKey:(NSData*)theirEphemeralPublicKey {
    NSMutableData *masterKey = [NSMutableData data];
    [masterKey appendData:[ourIdentityKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
    [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirIdentityPublicKey]];
    [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
    return masterKey;
}

-(NSData*)masterKeyBob:(TSECKeyPair*)ourIdentityKeyPair ourEphemeral:(TSECKeyPair*)ourEphemeralKeyPair theirIdentityPublicKey:(NSData*)theirIdentityPublicKey theirEphemeralPublicKey:(NSData*)theirEphemeralPublicKey {
    NSMutableData *masterKey = [NSMutableData data];
    
    if (!(ourEphemeralKeyPair && theirEphemeralPublicKey && ourIdentityKeyPair && theirIdentityPublicKey)) {
        DLog(@"Some parameters of are not defined");
    }
    
    [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirIdentityPublicKey]];
    [masterKey appendData:[ourIdentityKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
    [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
    return masterKey;
}

-(void)nextMessageKeysOnChain:(TSChainType)chain withCompletion:(getNextMessageKeyOnChain)block{
    [TSMessagesDatabase getCK:self.thread onChain:chain withCompletionBlock:^(NSData *CK) {
        int hmacKeyMK = 0x01;
        int hmacKeyCK = 0x02;
        NSData* nextMK = [Cryptography computeHMAC:CK withHMACKey:[NSData dataWithBytes:&hmacKeyMK length:sizeof(hmacKeyMK)]];
        NSData* nextCK = [Cryptography computeHMAC:CK  withHMACKey:[NSData dataWithBytes:&hmacKeyCK length:sizeof(hmacKeyCK)]];
        [TSMessagesDatabase setCK:nextCK onThread:self.thread onChain:chain withCompletionBlock:^(BOOL success) {
            [TSMessagesDatabase getNPlusPlus:self.thread onChain:chain withCompletionBlock:^(NSNumber *number) {
                block([self deriveTSWhisperMessageKeysFromMessageKey:nextMK]);
            }];
        }];
    }];
}

-(RKCK*) initialRootKey:(NSData*)masterKey {
    return [RKCK withData:[TSHKDF deriveKeyFromMaterial:masterKey outputLength:64 info:[@"WhisperText" dataUsingEncoding:NSASCIIStringEncoding]]];
}

-(TSWhisperMessageKeys*) deriveTSWhisperMessageKeysFromMessageKey:(NSData*)nextMessageKey_MK {
    NSData* newCipherKeyAndMacKey  = [TSHKDF deriveKeyFromMaterial:nextMessageKey_MK outputLength:64 info:[@"WhisperMessageKeys" dataUsingEncoding:NSASCIIStringEncoding]];
    NSData* cipherKey = [newCipherKeyAndMacKey subdataWithRange:NSMakeRange(0, 32)];
    NSData* macKey = [newCipherKeyAndMacKey subdataWithRange:NSMakeRange(32, 32)];
    // we want to return something here  or use this locally
    return [[TSWhisperMessageKeys alloc] initWithCipherKey:cipherKey macKey:macKey];
}

@end
