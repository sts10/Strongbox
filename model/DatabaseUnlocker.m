//
//  DatabaseUnlocker.m
//  Strongbox
//
//  Created by Strongbox on 07/01/2021.
//  Copyright © 2021 Mark McGuill. All rights reserved.
//

#import "DatabaseUnlocker.h"
#import "Serializator.h"
#import "Utils.h"
#import "Kdbx4Serialization.h"
#import "AutoFillManager.h"
#import "KeePassCiphers.h"
#import "WorkingCopyManager.h"
#import "StrongboxErrorCodes.h"
#import "Argon2KdfCipher.h"
#import "CrossPlatform.h"

#if TARGET_OS_IPHONE

#import "AppPreferences.h"

#endif

@interface DatabaseUnlocker ()

@property (nonnull, readonly) VIEW_CONTROLLER_PTR viewController;
@property UnlockDatabaseOnDemandUIProviderBlock onDemandUiProvider;

@property (readonly) id<SpinnerUI> spinnerUi;
@property (readonly) id<AlertingUI> alertingUi;

@property (nonnull, readonly) METADATA_PTR database;
@property (nonnull) UnlockDatabaseCompletionBlock completion;
@property BOOL keyFromConvenience;
@property BOOL forcedReadOnly;
@property BOOL isNativeAutoFillAppExtensionOpen;
@property BOOL offlineMode;

@property (readonly) id<ApplicationPreferences> applicationPreferences;
@property (readonly) id<SyncManagement> syncManagement;

@property (nonatomic, readonly) NSString *databaseUuid;

@end

@implementation DatabaseUnlocker

- (id<ApplicationPreferences>)applicationPreferences {
    return CrossPlatformDependencies.defaults.applicationPreferences;
}

- (id<SyncManagement>)syncManagement {
    return CrossPlatformDependencies.defaults.syncManagement;
}

- (id<SpinnerUI>)spinnerUi {
    return CrossPlatformDependencies.defaults.spinnerUi;
}

- (id<AlertingUI>)alertingUi {
    return CrossPlatformDependencies.defaults.alertingUi;
}

+ (instancetype)unlockerForDatabase:(METADATA_PTR)database
                     viewController:(VIEW_CONTROLLER_PTR)viewController
                      forceReadOnly:(BOOL)forcedReadOnly
                     isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen
                        offlineMode:(BOOL)offlineMode {
    return [DatabaseUnlocker unlockerForDatabase:database
                                   forceReadOnly:forcedReadOnly
                                  isNativeAutoFillAppExtensionOpen:isNativeAutoFillAppExtensionOpen
                                     offlineMode:offlineMode
                              onDemandUiProvider:^VIEW_CONTROLLER_PTR{
        return viewController;
    }];
}

+ (instancetype)unlockerForDatabase:(METADATA_PTR)database
                      forceReadOnly:(BOOL)forcedReadOnly
                     isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen
                        offlineMode:(BOOL)offlineMode
                 onDemandUiProvider:(UnlockDatabaseOnDemandUIProviderBlock)onDemandUiProvider {
    return [[DatabaseUnlocker alloc] initWithDatabase:database
                                       forcedReadOnly:forcedReadOnly
                     isNativeAutoFillAppExtensionOpen:isNativeAutoFillAppExtensionOpen
                                          offlineMode:offlineMode
                                   onDemandUiProvider:onDemandUiProvider];
}

- (instancetype)initWithDatabase:(METADATA_PTR)database
                  forcedReadOnly:(BOOL)forcedReadOnly
                  isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen
                     offlineMode:(BOOL)offlineMode
              onDemandUiProvider:(UnlockDatabaseOnDemandUIProviderBlock)onDemandUiProvider {
    self = [super init];
    
    if (self) {
        _databaseUuid = database.uuid;
        self.onDemandUiProvider = onDemandUiProvider;
        self.forcedReadOnly = forcedReadOnly;
        self.isNativeAutoFillAppExtensionOpen = isNativeAutoFillAppExtensionOpen;
        self.offlineMode = offlineMode;
        self.alertOnJustPwdWrong = YES; 
    }
    
    return self;
}

- (VIEW_CONTROLLER_PTR)viewController {
    return self.onDemandUiProvider();
}

- (void)showSpinner:(NSString*)status {
    if ( !self.noProgressSpinner ) {
        [self.spinnerUi show:status viewController:self.viewController];
    }
}

- (void)dismissSpinner {
    if ( !self.noProgressSpinner ) {
        [self.spinnerUi dismiss];
    }
}

- (METADATA_PTR)database {
    return [CommonDatabasePreferences fromUuid:self.databaseUuid];
}

+ (Model*)expressTryUnlockWithKey:(METADATA_PTR)database key:(CompositeKeyFactors *)key {
    if ( key.yubiKeyCR ) { 
        return nil;
    }
    
    NSURL* localCopyUrl = [WorkingCopyManager.sharedInstance getLocalWorkingCache:database.uuid];

    if(localCopyUrl == nil) {
        return nil;
    }
    
    NSError* error;
    BOOL valid = [Serializator isValidDatabase:localCopyUrl error:&error];
    if (!valid) {
        return nil;
    }
    
    __block DatabaseModel* ret = nil;

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    [Serializator fromUrl:localCopyUrl ckf:key completion:^(BOOL userCancelled, DatabaseModel * _Nullable model, NSError * _Nullable error) {
        if (!(userCancelled || error || !model) ) {
            ret = model;
        }
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    return ret ? [[Model alloc] initWithDatabase:ret
                                        metaData:database
                                  forcedReadOnly:NO
                                      isAutoFill:NO] : nil;
}

- (void)unlockLocalWithKey:(CompositeKeyFactors*)key
        keyFromConvenience:(BOOL)keyFromConvenience
                completion:(UnlockDatabaseCompletionBlock)completion {
    NSURL* localCopyUrl = [WorkingCopyManager.sharedInstance getLocalWorkingCache:self.database.uuid];

    if(localCopyUrl == nil) {
        [self.alertingUi warn:self.viewController
                        title:NSLocalizedString(@"open_sequence_couldnt_open_local_title", @"Could Not Open Local Copy")
                      message:NSLocalizedString(@"open_sequence_couldnt_open_local_message", @"Could not open Strongbox's local copy of this database. A online sync is required.")];
        completion(kUnlockDatabaseResultUserCancelled, nil, nil);
        return;
    }

    [self unlockAtUrl:localCopyUrl key:key keyFromConvenience:keyFromConvenience completion:completion];
}

- (void)unlockAtUrl:(NSURL*)url
                key:(CompositeKeyFactors*)key
 keyFromConvenience:(BOOL)keyFromConvenience
         completion:(UnlockDatabaseCompletionBlock)completion {
    [self warnAboutAutoFillCrash:url key:key keyFromConvenience:keyFromConvenience completion:completion];
    
    self.keyFromConvenience = keyFromConvenience;
    self.completion = completion;

    NSError* error;
    BOOL valid = [Serializator isValidDatabase:url error:&error];
    if (!valid) {
        [self openSafeWithDataDone:nil key:key error:error];
        return;
    }

    [self showSpinner:NSLocalizedString(@"open_sequence_progress_decrypting", @"Decrypting...")];
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        DatabaseFormat format = [Serializator getDatabaseFormat:url];
        if(!self.keyFromConvenience && (format == kKeePass || format == kKeePass4) && key.isAmbiguousEmptyOrNullPassword) {
            [self autoDetermineEmptyOrNullAmbiguousPassword:url key:key keyFromConvenience:keyFromConvenience completion:completion];
        }
        else {
            [Serializator fromUrl:url
                              ckf:key
                       completion:^(BOOL userCancelled, DatabaseModel * _Nullable model, NSError * _Nullable error) {
                [self onGotDatabaseModelFromData:userCancelled model:model key:key error:error];
            }];
        }
    });
}

- (void)onGotDatabaseModelFromData:(BOOL)userCancelled
                             model:(DatabaseModel*)model
                               key:(CompositeKeyFactors*)key
                             error:(NSError*)error {
    dispatch_async(dispatch_get_main_queue(), ^(void){
        [self dismissSpinner];
        
        if (userCancelled) {
            self.completion(kUnlockDatabaseResultUserCancelled, nil, nil);
        }
        else {
            [self openSafeWithDataDone:model key:key error:error];
        }
    });
}

- (void)openSafeWithDataDone:(DatabaseModel*)dbModel
                         key:(CompositeKeyFactors*)key
                       error:(NSError*)error {
    [self dismissSpinner];
    
    if (dbModel == nil) {
        [self doHapticFeedback:NO];

        if (!error) {
            NSLog(@"WARNWARN - No database but error not set?!");
            error = [Utils createNSError:NSLocalizedString(@"open_sequence_problem_opening_title", @"There was a problem opening the database.") errorCode:-1];
        }

        if ( error.code == StrongboxErrorCodes.incorrectCredentials ) {
            if(self.keyFromConvenience) {
                [self handleIncorrectConvenienceCredentials:error];
            }
            else {
                [self handleIncorrectManualCredentials:error key:key];
            }
        }
        else {
            self.completion(kUnlockDatabaseResultError, nil, error);
        }
    }
    else {
        [self onSuccessfulSafeOpen:dbModel];
    }
}

- (void)onSuccessfulSafeOpen:(DatabaseModel *)openedSafe {
    [self doHapticFeedback:YES];
    






            
    [self updateUnlockCountAndLikelyFormat:openedSafe];

    [self refreshConvenienceUnlockIfNecessary:openedSafe];
    
    Model *viewModel = [[Model alloc] initWithDatabase:openedSafe
                                              metaData:self.database
                                        forcedReadOnly:self.forcedReadOnly
                                            isAutoFill:self.isNativeAutoFillAppExtensionOpen
                                           offlineMode:self.offlineMode];
    
    [self updateQuickTypeAutoFill:viewModel];

    self.completion(kUnlockDatabaseResultSuccess, viewModel, nil);
}

- (void)refreshConvenienceUnlockIfNecessary:(DatabaseModel *)openedSafe  {
    if ( self.database.isConvenienceUnlockEnabled ) {
        BOOL expired = self.database.conveniencePasswordHasExpired;
        BOOL secretUnavailable = !self.database.conveniencePasswordHasBeenStored;
  
        if ( expired || secretUnavailable ) {
            NSLog(@"Convenience Unlock enabled, successful open, and password expired (%hhd) or unavailble (%hhd). refreshing stored secret.", expired, secretUnavailable);
            
            self.database.conveniencePasswordHasBeenStored = YES;
            self.database.convenienceMasterPassword = openedSafe.ckfs.password;
        }
    }
}
    
- (void)handleIncorrectConvenienceCredentials:(NSError *)error {
    

    self.database.conveniencePasswordHasBeenStored = NO;
    self.database.convenienceMasterPassword = nil;
    self.database.autoFillConvenienceAutoUnlockPassword = nil;
    
    [self.alertingUi info:self.viewController
                    title:NSLocalizedString(@"open_sequence_problem_opening_title", @"Could not open database")
                  message:NSLocalizedString(@"open_sequence_problem_opening_convenience_incorrect_message", @"The Convenience Password or Key File were incorrect for this database. Convenience Unlock Disabled.")
               completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completion(kUnlockDatabaseResultIncorrectCredentials, nil, error);
        });
    }];
}

- (void)handleIncorrectManualCredentials:(NSError *)error key:(CompositeKeyFactors *)key {
    if ( key.keyFileDigest ) {
        [self.alertingUi info:self.viewController
                        title:NSLocalizedString(@"open_sequence_problem_opening_incorrect_credentials_title", @"Incorrect Credentials")
                      message:NSLocalizedString(@"open_sequence_problem_opening_incorrect_credentials_message_verify_key_file", @"The credentials were incorrect for this database. Are you sure you are using this key file?\n\nNB: A key files are not the same as your database file.")
                   completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self.completion(kUnlockDatabaseResultIncorrectCredentials, nil, error);
            });
        }];
    }
    else {
        if ( self.alertOnJustPwdWrong || key.yubiKeyCR ) {
            [self.alertingUi info:self.viewController
                            title:NSLocalizedString(@"open_sequence_problem_opening_incorrect_credentials_title", @"Incorrect Credentials")
                          message:NSLocalizedString(@"open_sequence_problem_opening_incorrect_credentials_message", @"The credentials were incorrect for this database.")
                       completion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.completion(kUnlockDatabaseResultIncorrectCredentials, nil, error);
                });
            }];
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.completion(kUnlockDatabaseResultIncorrectCredentials, nil, error);
            });
        }
    }
}

- (void)autoDetermineEmptyOrNullAmbiguousPassword:(NSURL*)url
                                              key:(CompositeKeyFactors*)key
                               keyFromConvenience:(BOOL)keyFromConvenience
                                       completion:(UnlockDatabaseCompletionBlock)completion {
    
    
    
    
    
    CompositeKeyFactors *emptyPw = [CompositeKeyFactors password:@"" keyFileDigest:key.keyFileDigest yubiKeyCR:key.yubiKeyCR];
    CompositeKeyFactors *nilPw = [CompositeKeyFactors password:nil keyFileDigest:key.keyFileDigest yubiKeyCR:key.yubiKeyCR];

    CompositeKeyFactors *firstCheck = self.database.emptyOrNilPwPreferNilCheckFirst ? nilPw : emptyPw;
    CompositeKeyFactors *secondCheck = self.database.emptyOrNilPwPreferNilCheckFirst ? emptyPw : nilPw;
    
    [Serializator fromUrl:url
                      ckf:firstCheck
               completion:^(BOOL userCancelled, DatabaseModel * _Nullable model, NSError * _Nullable error) {
        if(model == nil && error && error.code == StrongboxErrorCodes.incorrectCredentials) {
            NSLog(@"INFO: Empty/Nil Password check didn't work first time! will try alternative password...");
            
            self.database.emptyOrNilPwPreferNilCheckFirst = !self.database.emptyOrNilPwPreferNilCheckFirst;
                        
            if ( secondCheck.yubiKeyCR != nil ) {
                
                
                [self dismissSpinner]; 
                
                [self.alertingUi info:self.viewController
                                title:NSLocalizedString(@"yubikey_fast_unlock_title", @"Determining Fast Unlock for YubiKey")
                              message:NSLocalizedString(@"yubikey_fast_unlock_message", @"Strongbox is determining the fastest way to unlock this database. You will be asked to scan your YubiKey once again.")
                           completion:^{
                    [Serializator fromUrl:url
                                      ckf:secondCheck
                               completion:^(BOOL userCancelled, DatabaseModel * _Nullable model, NSError * _Nullable error) {
                        [self onGotDatabaseModelFromData:userCancelled model:model key:secondCheck error:error];
                    }];
                }];
            }
            else {
                [Serializator fromUrl:url
                                  ckf:secondCheck
                           completion:^(BOOL userCancelled, DatabaseModel * _Nullable model, NSError * _Nullable error) {
                    [self onGotDatabaseModelFromData:userCancelled model:model key:secondCheck error:error];
                }];
            }
        }
        else {
            [self onGotDatabaseModelFromData:userCancelled model:model key:firstCheck error:error];
        }
    }];
}



+ (BOOL)isAutoFillLikelyToCrash:(NSURL*)url {
    DatabaseFormat format = [Serializator getDatabaseFormat:url];
    
    if ( format == kKeePass4 ) {     
        NSInputStream* inputStream = [NSInputStream inputStreamWithURL:url];
        CryptoParameters* params = [Kdbx4Serialization getCryptoParams:inputStream];

        if(params && params.kdfParameters && ( [params.kdfParameters.uuid isEqual:argon2dCipherUuid()] || [params.kdfParameters.uuid isEqual:argon2idCipherUuid()])) {
            Argon2KdfCipher* cip = [[Argon2KdfCipher alloc] initWithParametersDictionary:params.kdfParameters];
            if( cip.memory > Argon2KdfCipher.maxRecommendedMemory ) {
                return YES;
            }
        }
    }
    
    return NO;
}

- (void)updateQuickTypeAutoFill:(Model*)openedSafe {
    if ( self.database.autoFillEnabled && self.database.quickTypeEnabled && !self.isNativeAutoFillAppExtensionOpen ) {
        
        
        [AutoFillManager.sharedInstance updateAutoFillQuickTypeDatabase:openedSafe
                                                           databaseUuid:self.database.uuid
                                                          displayFormat:self.database.quickTypeDisplayFormat
                                                        alternativeUrls:self.database.autoFillScanAltUrls
                                                           customFields:self.database.autoFillScanCustomFields
                                                                  notes:self.database.autoFillScanNotes
                                           concealedCustomFieldsAsCreds:self.database.autoFillConcealedFieldsAsCreds
                                         unConcealedCustomFieldsAsCreds:self.database.autoFillUnConcealedFieldsAsCreds nickName:self.database.nickName];
    }
}

- (void)updateUnlockCountAndLikelyFormat:(DatabaseModel*)openedSafe {
    if ( !self.isNativeAutoFillAppExtensionOpen ) { 
        
        
        self.database.likelyFormat = openedSafe.originalFormat;
        self.database.unlockCount++;
    }
}

- (void)doHapticFeedback:(BOOL)success {
#if TARGET_OS_IPHONE
    UINotificationFeedbackGenerator* gen = [[UINotificationFeedbackGenerator alloc] init];
    [gen notificationOccurred:success ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
#endif
}

- (void)warnAboutAutoFillCrash:(NSURL*)url
                           key:(CompositeKeyFactors*)key
            keyFromConvenience:(BOOL)keyFromConvenience
                    completion:(UnlockDatabaseCompletionBlock)completion {
#if TARGET_OS_IPHONE
    if ( self.isNativeAutoFillAppExtensionOpen && !AppPreferences.sharedInstance.haveWarnedAboutAutoFillCrash && [DatabaseUnlocker isAutoFillLikelyToCrash:url] ) {
        AppPreferences.sharedInstance.haveWarnedAboutAutoFillCrash = YES;

        [self.alertingUi warn:self.viewController
                        title:NSLocalizedString(@"open_sequence_autofill_creash_likely_title", @"AutoFill Crash Likely")
                      message:NSLocalizedString(@"open_sequence_autofill_creash_likely_message", @"Your database has encryption settings that may cause iOS Password AutoFill extensions to be terminated due to excessive resource consumption. This will mean AutoFill appears not to work. Unfortunately this is an Apple imposed limit. You could consider reducing the amount of resources consumed by your encryption settings (Memory in particular with Argon2 to below 64MB).")
                   completion:^{
            [self unlockAtUrl:url key:key keyFromConvenience:keyFromConvenience completion:completion];
        }];
        
        return;
    }
#endif
}

@end
