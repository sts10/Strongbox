//
//  SelectAutoFillDatabaseViewController.h
//  Strongbox AutoFill
//
//  Created by Strongbox on 26/11/2020.
//  Copyright © 2020 Mark McGuill. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MacDatabasePreferences.h"
#import "MMWormhole.h"

NS_ASSUME_NONNULL_BEGIN

@interface SelectDatabaseViewController : NSViewController

+ (instancetype)fromStoryboard;

@property (nonatomic, copy) void (^onDone)(BOOL userCancelled, MacDatabasePreferences*_Nullable database);
@property MMWormhole* wormhole;
@property BOOL autoFillMode;
@property (nullable) NSSet<NSString*>* disabledDatabases;
@end

NS_ASSUME_NONNULL_END
