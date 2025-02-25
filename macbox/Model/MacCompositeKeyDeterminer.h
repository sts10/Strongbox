//
//  MacCompositeKeyDeterminer.h
//  MacBox
//
//  Created by Strongbox on 01/11/2021.
//  Copyright © 2021 Mark McGuill. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CompositeKeyDeterminer.h"
#import "CommonDatabasePreferences.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSViewController* _Nonnull (^MacCompositeKeyDeterminerOnDemandUIProviderBlock)(void); // Allows lazy creation of UI only when required, so we can run very silently / in background

@interface MacCompositeKeyDeterminer : NSObject

+ (instancetype)determinerWithViewController:(NSViewController*_Nullable)viewController
                                    database:(METADATA_PTR)database
            isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen;

+ (instancetype)determinerWithViewController:(NSViewController*_Nullable)viewController
                                    database:(METADATA_PTR)database
            isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen
                     isAutoFillQuickTypeOpen:(BOOL)isAutoFillQuickTypeOpen;

+ (instancetype)determinerWithDatabase:(METADATA_PTR)database
      isNativeAutoFillAppExtensionOpen:(BOOL)isNativeAutoFillAppExtensionOpen
               isAutoFillQuickTypeOpen:(BOOL)isAutoFillQuickTypeOpen
                    onDemandUiProvider:(MacCompositeKeyDeterminerOnDemandUIProviderBlock)onDemandUiProvider;

- (void)getCkfs:(CompositeKeyDeterminedBlock)completion;

- (void)getCkfsManually:(CompositeKeyDeterminedBlock)completion;

- (void)getCkfsWithBiometrics:(NSString*_Nullable)keyFileBookmark
         yubiKeyConfiguration:(YubiKeyConfiguration*_Nullable)yubiKeyConfiguration
                   completion:(CompositeKeyDeterminedBlock)completion;

- (void)getCkfsWithExplicitPassword:(NSString*_Nullable)password
                    keyFileBookmark:(NSString*_Nullable)keyFileBookmark
               yubiKeyConfiguration:(YubiKeyConfiguration*_Nullable)yubiKeyConfiguration
                         completion:(CompositeKeyDeterminedBlock)completion;

@property (readonly) BOOL bioOrWatchUnlockIsPossible;
@property BOOL createWindowForManualCredentialsEntry;

+ (BOOL)bioOrWatchUnlockIsPossible:(MacDatabasePreferences*)database;



+ (CompositeKeyFactors* _Nullable)getCkfsWithConfigs:(NSString*_Nullable)password
                                     keyFileBookmark:(NSString*_Nullable)keyFileBookmark
                                yubiKeyConfiguration:(YubiKeyConfiguration*_Nullable)yubiKeyConfiguration
                hardwareKeyInteractionViewController:(NSViewController*)hardwareKeyInteractionViewController
                                   formatKeyFileHint:(DatabaseFormat)formatKeyFileHint
                                               error:(NSError**)outError;
@end

NS_ASSUME_NONNULL_END
