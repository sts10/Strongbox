//
//  AppDelegate.m
//  MacBox
//
//  Created by Mark on 01/08/2017.
//  Copyright © 2017 Mark McGuill. All rights reserved.
//

#import "AppDelegate.h"
#import "DocumentController.h"
#import "Settings.h"
#import "MacAlerts.h"
#import "Utils.h"
#import "Strongbox.h"
#import "BiometricIdHelper.h"
#import "ViewController.h"
#import "SafeStorageProviderFactory.h"
#import "AboutViewController.h"
#import "ClipboardManager.h"
#import "DebugHelper.h"
#import "MacUrlSchemes.h"
#import "Shortcut.h"
#import "NodeDetailsViewController.h"
#import "Document.h"
#import "SystemTrayViewController.h"
#import "MainWindow.h"
#import "LockScreenViewController.h"
#import "CsvImporter.h"
#import "Csv.h"
#import "NSArray+Extensions.h"
#import "CreateFormatAndSetCredentialsWizard.h"
#import "MacSyncManager.h"
#import "macOSSpinnerUI.h"
#import "Constants.h"
#import "Serializator.h"
#import "MacCustomizationManager.h"
#import "ProUpgradeIAPManager.h"
#import "UpgradeWindowController.h"
#import "AutoFillProxyServer.h"
#import "Strongbox-Swift.h"

#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS 
    #import "GoogleDriveStorageProvider.h"
    #import "DropboxV2StorageProvider.h"
#endif

#ifndef NO_SFTP_WEBDAV_SP
    #import "WebDAVStorageProvider.h"
    #import "SFTPStorageProvider.h"
    #import "WebDAVConnections.h"
    #import "SFTPConnections.h"
    #import "SFTPConnectionsManager.h"
#endif

NSString* const kUpdateNotificationQuickRevealStateChanged = @"kUpdateNotificationQuickRevealStateChanged";
static NSString* const kAutoLockIfInBackgroundNotification = @"autoLockAppInBackgroundTimeout";

const NSInteger kTopLevelMenuItemTagStrongbox = 1110;
const NSInteger kTopLevelMenuItemTagFile = 1111;
const NSInteger kTopLevelMenuItemTagView = 1113;



@interface AppDelegate () <NSPopoverDelegate>

@property (strong) IBOutlet NSMenu *systemTraymenu;
@property NSStatusItem* statusItem;

@property NSTimer* clipboardChangeWatcher;
@property NSInteger currentClipboardVersion;
@property NSPopover* systemTrayPopover;
@property NSDate* systemTrayPopoverClosedAt;
@property NSTimer* timerRefreshOtp;
@property NSDate* appLaunchTime;

@property BOOL explicitQuitRequest;
@property BOOL firstActivationDone;
@property BOOL wasLaunchedAsLoginItem;

@property (strong, nonatomic) dispatch_block_t autoLockWorkBlock;

@end

@implementation AppDelegate

- (id)init {
    self = [super init];
    
    
    
    
    DocumentController *dc = [[DocumentController alloc] init];
    
    if(dc) {} 
    
    return self;
}

- (BOOL)isWasLaunchedAsLoginItem {
    return self.wasLaunchedAsLoginItem;
}

- (void)determineIfLaunchedAsLoginItem {
    
    
    

    NSAppleEventDescriptor* event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    if ( event.eventID == kAEOpenApplication &&
        [[event paramDescriptorForKeyword:keyAEPropData] enumCodeValue] == keyAELaunchedAsLogInItem) {
        NSLog(@"Strongbox was launched as a login item!");
        self.wasLaunchedAsLoginItem = YES;
    }
    else {
        NSLog(@"Strongbox was NOT launched as a login item - just a regular launch");
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    
    
    
    
    

    [self determineIfLaunchedAsLoginItem];
    
    
    
    
    [self initializeInstallSettingsAndLaunchCount];
    
    [self doInitialSetup];

    [self listenToEvents];
    
    [self startAutoFillProxyServer];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self doDeferredAppLaunchTasks]; 
    });
}

- (void)startAutoFillProxyServer {
    if ( Settings.sharedInstance.runBrowserAutoFillProxyServer && Settings.sharedInstance.isPro ) {
        [NativeMessagingManifestInstallHelper installNativeMessagingHostsFiles];
        
        if ( ![AutoFillProxyServer.sharedInstance start] ) {
            NSLog(@"🔴 Failed to start AutoFillProxyServer.");
        }
    }
    else {
        [NativeMessagingManifestInstallHelper removeNativeMessagingHostsFiles];
    }
}

- (void)initializeInstallSettingsAndLaunchCount {
    [Settings.sharedInstance incrementLaunchCount];
    
    if(Settings.sharedInstance.installDate == nil) {
        Settings.sharedInstance.installDate = NSDate.date;
    }
}

- (void)doInitialSetup {
#ifdef DEBUG
    
    
    [NSUserDefaults.standardUserDefaults setValue:@(NO) forKey:@"NSConstraintBasedLayoutLogUnsatisfiable"];
    [NSUserDefaults.standardUserDefaults setValue:@(NO) forKey:@"__NSConstraintBasedLayoutLogUnsatisfiable"];
#else
    [self cleanupWorkingDirectories];
#endif
    
    self.appLaunchTime = [NSDate date];

    [MacCustomizationManager applyCustomizations];

    [self removeUnwantedMenuItems];

    [self setupSystemTrayPopover];
    
    [self showHideSystemStatusBarIcon];
    
    [self installGlobalHotKeys];
            
    [self clearAsyncUpdateIdsAndEphemeralOfflineFlags]; 
    
    [self startRefreshOtpTimer];

    [self bindFreeOrProStatus];

    if ( !MacCustomizationManager.isAProBundle ) {
        [ProUpgradeIAPManager.sharedInstance initialize]; 
    }
    
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
    [DropboxV2StorageProvider.sharedInstance initialize:Settings.sharedInstance.useIsolatedDropbox];
#endif
}

- (void)doDeferredAppLaunchTasks {
    [MacOnboardingManager beginAppOnboardingWithCompletion:^{
        NSLog(@"✅ Onboarding Completed...");

        [self checkForAllWindowsClosedScenario:nil appIsLaunching:YES];
    }];

    [self monitorForQuickRevealKey];
    
    [MacSyncManager.sharedInstance backgroundSyncOutstandingUpdates];
}

- (void)setupSystemTrayPopover {
    self.systemTrayPopover = [[NSPopover alloc] init];
    self.systemTrayPopover.behavior = NSPopoverBehaviorTransient ;
    self.systemTrayPopover.animates = NO;

    SystemTrayViewController *vc = [SystemTrayViewController instantiateFromStoryboard];
    vc.onShowClicked = ^(NSString * _Nullable databaseToShowUuid) {
        [self onSystemTrayShow:databaseToShowUuid];
    };
    vc.popover = self.systemTrayPopover;

    self.systemTrayPopover.contentViewController = vc;
    self.systemTrayPopover.delegate = self;
}

- (void)performedScheduledEntitlementsCheck {
    NSTimeInterval timeDifference = [NSDate.date timeIntervalSinceDate:self.appLaunchTime];
    double minutes = timeDifference / 60;

    if( minutes > 30 ) {
        [ProUpgradeIAPManager.sharedInstance performScheduledProEntitlementsCheckIfAppropriate];
    }
}

- (void)monitorForQuickRevealKey {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                          handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if ( ( event.keyCode == 58 || event.keyCode == 61 ) && Settings.sharedInstance.quickRevealWithOptionKey ) {
            BOOL optionKeyDown = ((event.modifierFlags & NSEventModifierFlagOption) == NSEventModifierFlagOption);



            [NSNotificationCenter.defaultCenter postNotificationName:kUpdateNotificationQuickRevealStateChanged
                                                              object:@(optionKeyDown)
                                                            userInfo:nil];
        }
        
        return event;
    }];
}

- (void)listenToEvents {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onWindowDidMiniaturize:)
                                                 name:NSWindowDidMiniaturizeNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onWindowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:nil];





    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onPreferencesChanged:)
                                                 name:kPreferencesChangedNotification
                                               object:nil];
    
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onProStatusChanged:) name:kProStatusChangedNotificationKey object:nil];
    
    
    
    [NSAppleEventManager.sharedAppleEventManager setEventHandler:self
                                                     andSelector:@selector(handleGetURLEvent:withReplyEvent:)
                                                   forEventClass:kInternetEventClass
                                                      andEventID:kAEGetURL];
    
    
    
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(onLogoutRestartOrShutdown:)
                                                           name:NSWorkspaceWillPowerOffNotification
                                                         object:nil];
}

- (void)cleanupWorkingDirectories {
    [StrongboxFilesManager.sharedInstance deleteAllTmpAttachmentPreviewFiles];
    [StrongboxFilesManager.sharedInstance deleteAllTmpWorkingFiles];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
    NSString *URLString = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    NSURL *url = [NSURL URLWithString:URLString];


    
    if ( [url.absoluteString hasPrefix:@"com.googleusercontent.apps"] ) {
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
        [GoogleDriveManager.sharedInstance handleUrl:url];
#endif
    }
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
    else if ([url.absoluteString hasPrefix:@"db"]) {
        [DropboxV2StorageProvider.sharedInstance handleAuthRedirectUrl:url];
        [NSRunningApplication.currentApplication activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    }
#endif
}

- (BOOL)isWindowOfInterest:(NSNotification*)notification {
    return ( [notification.object isMemberOfClass:MainWindow.class] ||
            [notification.object isMemberOfClass:DatabasesManagerWindow.class] ||
            [notification.object isMemberOfClass:NextGenWindow.class]);
}

- (void)onWindowWillClose:(NSNotification*)notification {

    
    if ( ![self isWindowOfInterest:notification] ) { 

        return;
    }

    [self checkForAllWindowsClosedScenario:notification.object appIsLaunching:NO];
}

- (void)onWindowDidMiniaturize:(NSNotification*)notification {
    NSLog(@"onWindowDidMiniaturizeOrClose");

    if ( ![self isWindowOfInterest:notification] ) { 

        return;
    }
















    
    [self checkForAllWindowsClosedScenario:nil appIsLaunching:NO];
}

- (void)checkForAllWindowsClosedScenario:(NSWindow*)windowAboutToBeClosed appIsLaunching:(BOOL)appIsLaunching {
    NSLog(@"✅ AppDelegate::checkForAllWindowsClosedScenario - currentEvent = [%@]", NSApp.currentEvent);
    
    NSArray* docs = DocumentController.sharedDocumentController.documents;
    NSMutableArray* mainWindows = [docs map:^id _Nonnull(id  _Nonnull obj, NSUInteger idx) {
        Document* doc = obj;
        NSWindowController* wc = (NSWindowController*)doc.windowControllers.firstObject;
        return wc.window;
    }].mutableCopy;





    if ( windowAboutToBeClosed ) {

        [mainWindows removeObject:windowAboutToBeClosed];
    }
    
    BOOL allMiniaturizedOrClosed = [mainWindows allMatch:^BOOL(NSWindow * _Nonnull obj) {
        return obj.miniaturized;
    }];
    
    if ( allMiniaturizedOrClosed ) {
        [self onAllWindowsClosed:windowAboutToBeClosed appIsLaunching:appIsLaunching];
    }
    else {







    }
}

- (void)onAllWindowsClosed:(NSWindow*)windowAboutToBeClosed appIsLaunching:(BOOL)appIsLaunching {
    if ( appIsLaunching ) {
        if ( Settings.sharedInstance.showDatabasesManagerOnAppLaunch ) {
            if ( self.isWasLaunchedAsLoginItem && Settings.sharedInstance.showSystemTrayIcon ) {
                NSLog(@"AppDelegate::onAllWindowsClosed -> App Launching and no windows visible but was launched as a login item so NOP - Silent Launch - Hiding Dock Icon");
                
                [self showHideDockIcon:NO];
            }
            else {
                NSLog(@"AppDelegate::onAllWindowsClosed -> App Launching and no windows visible - Showing Databases Manager because so configured");
                
                [DBManagerPanel.sharedInstance show];
            }
        }
        else if ( Settings.sharedInstance.configuredAsAMenuBarApp ) {
            
            NSLog(@"AppDelegate::onAllWindowsClosed -> App Launching and no windows visible - Running as a tray app so NOT showing Databases Manager");
            
            [self showHideDockIcon:NO];
        }
    }
    else {
        
        








            if ( Settings.sharedInstance.configuredAsAMenuBarApp ) {
                NSLog(@"✅ AppDelegate::onAllWindowsClosed -> all windows have either just been miniaturized or closed... running as a tray app - hiding dock icon.");
                
                [self showHideDockIcon:NO];
            }
            else {
                NSLog(@"✅ AppDelegate::onAllWindowsClosed -> all windows have either just been miniaturized or closed... but configured to do nothing special.");
            }

    }
}

- (void)showHideDockIcon:(BOOL)show {
    NSLog(@"🚀 AppDelegate::showHideDockIcon: [%@] - [%@]", (long)show ? @"SHOW" : @"HIDE", NSThread.currentThread);

    if ( show ) {
        if ( NSApp.activationPolicy != NSApplicationActivationPolicyAccessory ) {
            NSLog(@"Dock Icon already visible - NOP"); 
            return;
        }
        
        
        
        
        
        
        
        
        
        
        
        BOOL ret = [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSLog(@"🚀 AppDelegate::NSApplicationActivationPolicyProhibited: %@", localizedYesOrNoFromBool(ret));
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL ret = [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSLog(@"🚀 AppDelegate::NSApplicationActivationPolicyRegular: %@", localizedYesOrNoFromBool(ret));
            
            
            
            [NSApp activateIgnoringOtherApps:YES];
            [NSApp arrangeInFront:nil];
            
            NSLog(@"🚀 AppDelegate::showHideDockIcon: mainWindow = [%@]", NSApplication.sharedApplication.mainWindow);
            
            [NSApplication.sharedApplication.mainWindow makeKeyAndOrderFront:nil];
        });
    }
    else {
        
        
        
        
        BOOL ret = [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSLog(@"🚀 AppDelegate::NSApplicationActivationPolicyAccessory: %@", localizedYesOrNoFromBool(ret));
    }
}

- (BOOL)isHiddenToTray {
    BOOL ret = NSApp.activationPolicy != NSApplicationActivationPolicyRegular;
    
    NSLog(@"isHiddenToTray: %@", localizedYesOrNoFromBool(ret));
    
    return ret;
}

- (void)showHideSystemStatusBarIcon {
    NSLog(@"AppDelegate::showHideSystemStatusBarIcon");
    
    if (Settings.sharedInstance.showSystemTrayIcon) {
        if (!self.statusItem) {
            NSImage* statusImage = [NSImage imageNamed:@"AppIcon-glyph"];
            statusImage.size = NSMakeSize(18.0, 18.0);
            self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
            self.statusItem.button.image = statusImage;
            self.statusItem.highlightMode = YES;
            self.statusItem.button.enabled = YES;

        
            





                [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp];
                self.statusItem.button.action = @selector(onSystemTrayIconClicked:);

        }
    }
    else {
        if(self.statusItem) {
            [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
            self.statusItem = nil;
        }
    }
}

- (void)popoverDidShow:(NSNotification *)notification {

}

- (void)popoverDidClose:(NSNotification *)notification {





    
    self.systemTrayPopoverClosedAt = NSDate.date;
}

- (void)onSystemTrayIconClicked:(id)sender {
    NSLog(@"onSystemTrayIconClicked [%@]", self.systemTrayPopover.contentViewController);

    NSTimeInterval interval = [NSDate.date timeIntervalSinceDate:self.systemTrayPopoverClosedAt];

    
    
    
    if ( self.systemTrayPopoverClosedAt == nil || interval > 0.2f ) {
        
        
        NSView* v = sender;
        NSView* positioningView = [[NSView alloc] initWithFrame:v.bounds];
        positioningView.identifier = (NSUserInterfaceItemIdentifier)@"positioningView";
        [v addSubview:positioningView];
        
        [self.systemTrayPopover showRelativeToRect:positioningView.bounds ofView:positioningView preferredEdge:NSRectEdgeMinY];
        v.bounds = NSOffsetRect(v.bounds, 0, v.bounds.size.height);

        NSWindow* popoverWindow = self.systemTrayPopover.contentViewController.view.window;
        if ( popoverWindow ) {
            [popoverWindow setFrame:CGRectOffset(popoverWindow.frame, 0, 13) display:NO];
        }
            
        [self.systemTrayPopover.contentViewController.view.window makeKeyWindow]; 
    }
}

- (IBAction)onSystemTrayShow:(id)sender {
    [self showAndActivateStrongbox:sender];
}

- (void)showAndActivateStrongbox:(NSString*_Nullable)databaseUuid {
    NSLog(@"🚀 showAndActivateStrongbox: [%@] - BEGIN", databaseUuid);

    [self showHideDockIcon:YES];
    
    for ( NSWindow* win in [NSApp windows] ) { 
        if([win isMiniaturized]) {
            [win deminiaturize:self];
        }
    }
        
    DocumentController* dc = NSDocumentController.sharedDocumentController;
    
    if ( databaseUuid ) {
        MacDatabasePreferences* metadata = [MacDatabasePreferences fromUuid:databaseUuid];
        if ( metadata ) {
            [dc openDatabase:metadata completion:nil];
        }
    }
    else {
        [dc launchStartupDatabasesOrShowManagerIfNoDocumentsAvailable];
    }

    [NSApplication.sharedApplication.mainWindow makeKeyAndOrderFront:nil];
    [NSApp arrangeInFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    

    NSLog(@"🚀 showAndActivateStrongbox: [%@] - END", databaseUuid);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if(Settings.sharedInstance.clearClipboardEnabled) {
        [self clearClipboardWhereAppropriate];
    }
    
    
    
    [self clearAppCustomClipboard];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"✅ applicationDidBecomeActive - START - [%@]", notification);

    [self cancelAutoLockInBackgroundTimer];
    
    [self performedScheduledEntitlementsCheck];
    
    if ( !self.firstActivationDone ) {
        self.firstActivationDone = YES;
        
        NSLog(@"✅ applicationDidBecomeActive - First Activation");

        DocumentController* dc = NSDocumentController.sharedDocumentController;

        [dc onAppStartup];
    }
    else if ( !self.isRequestingAutoFillManualCredentialsEntry ) {
        if ( [self isHiddenToTray] ) {
            NSLog(@"✅ applicationDidBecomeActive - isHiddenToTray - showing dock icon and and activating");
            
            
            
            
            
            
            
            
            [self showAndActivateStrongbox:nil];
        }
        else {







            
            
            
            
            
        }
    }
    else {
        NSLog(@"✅ applicationDidBecomeActive - Activated due to AutoFill Manual Credentials Entry request - NOP");
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    NSLog(@"✅ AppDelegate::applicationShouldHandleReopen: hasVisibleWindows = [%@]", localizedYesOrNoFromBool(hasVisibleWindows));

    
    
    
    if ( !hasVisibleWindows ) {
        DocumentController* dc = NSDocumentController.sharedDocumentController;
        [dc launchStartupDatabasesOrShowManagerIfNoDocumentsAvailable];
    }
    
    return YES;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    NSLog(@"✅ AppDelegate::applicationShouldOpenUntitledFile");
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    return NO;
}

- (void)applicationDidResignActive:(NSNotification *)notification {
        NSLog(@"🐞 DEBUG - [applicationDidResignActive]");
    
    [self startAutoLockForAppInBackgroundTimer];
}

- (void)cancelAutoLockInBackgroundTimer {
    if(self.autoLockWorkBlock) {
        NSLog(@"🐞 DEBUG - Cancelling Background Auto-Lock work block");
        dispatch_block_cancel(self.autoLockWorkBlock);
        self.autoLockWorkBlock = nil;
    }
}

- (void)startAutoLockForAppInBackgroundTimer {
    NSInteger timeout = Settings.sharedInstance.autoLockIfInBackgroundTimeoutSeconds;
    
    if(timeout != 0) {
        [self cancelAutoLockInBackgroundTimer];
        
        NSLog(@"🐞 DEBUG - [startAutoLockForAppInBackgroundTimer] Creating Background Auto-Lock work block... [timeout = %ld secs]", timeout);

        self.autoLockWorkBlock = dispatch_block_create(0, ^{
            NSLog(@"🐞 DEBUG - App in Background timeout exceeded -> Sending Notification...");
            
            [[NSNotificationCenter defaultCenter] postNotificationName:kAutoLockIfInBackgroundNotification object:nil];
            self.autoLockWorkBlock = nil;
        });
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), self.autoLockWorkBlock);
    }
}

- (void)randomlyShowUpgradeMessage {
    NSUInteger random = arc4random_uniform(100);
    
    NSUInteger showPercentage = 15;
    if(random < showPercentage) {
        [((AppDelegate*)[[NSApplication sharedApplication] delegate]) showUpgradeModal:YES];
    }
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem {
    SEL theAction = [anItem action];
    
    if (theAction == @selector(onFloatOnTopToggle:)) {
        NSMenuItem* item = (NSMenuItem*) anItem;
        [item setState:Settings.sharedInstance.floatOnTop ? NSControlStateValueOn : NSControlStateValueOff];
    }
    else if (theAction == @selector(signOutOfOneDrive:)) {



        return YES;
    }
    else if (theAction == @selector(signOutOfDropbox:)) {
        return YES; 
    }
    else if (theAction == @selector(signOutOfGoogleDrive:)) {
        return YES; 
    }

    return YES;
}

- (IBAction)signOutOfGoogleDrive:(id)sender {
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
    [GoogleDriveManager.sharedInstance signout];
#endif
}

- (IBAction)signOutOfOneDrive:(id)sender {
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
    [TwoDriveStorageProvider.sharedInstance signOutAll];
#endif
}

- (IBAction)signOutOfDropbox:(id)sender {
#ifndef NO_3RD_PARTY_STORAGE_PROVIDERS
    [DropboxV2StorageProvider.sharedInstance signOut];
#endif
}



- (void)installGlobalHotKeys {
    MASShortcut *globalShowShortcut = [MASShortcut shortcutWithKeyCode:kVK_ANSI_K modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagOption];
    NSData *globalLaunchShortcutData = [NSKeyedArchiver archivedDataWithRootObject:globalShowShortcut];

    [NSUserDefaults.standardUserDefaults registerDefaults:@{ kPreferenceGlobalShowShortcut : globalLaunchShortcutData }];
    
    [MASShortcutBinder.sharedBinder bindShortcutWithDefaultsKey:kPreferenceGlobalShowShortcut toAction:^{
        [self showAndActivateStrongbox:nil];
    }];
}

- (IBAction)onAbout:(id)sender {
    [AboutViewController show];
}

- (void)removeUnwantedMenuItems {
    [self removeMenuItem:kTopLevelMenuItemTagFile action:@selector(duplicateDocument:)];
    [self removeMenuItem:kTopLevelMenuItemTagFile action:@selector(saveDocumentAs:)];
    [self removeMenuItem:kTopLevelMenuItemTagFile action:@selector(renameDocument:)];
    [self removeMenuItem:kTopLevelMenuItemTagFile action:@selector(moveDocument:)];
    
    if ( !StrongboxProductBundle.supports3rdPartyStorageProviders ) {
        NSMenu* fileMenu = [NSApplication.sharedApplication.mainMenu itemWithTag:kTopLevelMenuItemTagFile].submenu;
        
        
        
        NSInteger idx = [fileMenu indexOfItemWithTag:24121980];
        [fileMenu removeItemAtIndex:idx];
    }
    
#ifndef DEBUG
    [self removeMenuItem:kTopLevelMenuItemTagFile action:@selector(onDumpXml:)];
#endif
    
    
    
    
    
    NSMenu* fileMenu = [NSApplication.sharedApplication.mainMenu itemWithTag:kTopLevelMenuItemTagFile].submenu;
    NSInteger openDocumentMenuItemIndex = [fileMenu indexOfItemWithTarget:nil andAction:@selector(originalOpenDocument:)];

    if (openDocumentMenuItemIndex>=0 &&
        [[fileMenu itemAtIndex:openDocumentMenuItemIndex+1] hasSubmenu])
    {
        
        
        
        [fileMenu removeItemAtIndex:openDocumentMenuItemIndex+1];
    }
    
    
    

}

- (void)removeMenuItem:(NSInteger)topLevelTag action:(SEL)action {
    NSMenu* topLevelMenuItem = [NSApplication.sharedApplication.mainMenu itemWithTag:topLevelTag].submenu;
    
    NSUInteger index = [topLevelMenuItem.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return obj.action == action;
    }];
    
    if( topLevelMenuItem &&  index != NSNotFound) {

        [topLevelMenuItem removeItemAtIndex:index];
    }
    else {

    }
}

- (void)changeMenuItemKeyEquivalent:(NSInteger)topLevelTag action:(SEL)action keyEquivalent:(NSString*)keyEquivalent modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenu* topLevelMenuItem = [NSApplication.sharedApplication.mainMenu itemWithTag:topLevelTag].submenu;
    
    NSUInteger index = [topLevelMenuItem.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return obj.action == action;
    }];
    
    if( topLevelMenuItem && index != NSNotFound) {
        NSMenuItem* menuItem = [topLevelMenuItem itemAtIndex:index];
        if ( menuItem ) {
            [menuItem setKeyEquivalentModifierMask:modifierMask];
            [menuItem setKeyEquivalent:keyEquivalent];
        }
    }
    else {
        NSLog(@"WARN: Menu Item %@ not found to remove.", NSStringFromSelector(action));
    }
}

- (IBAction)onViewDatabases:(id)sender {
    [DBManagerPanel.sharedInstance show];
}

- (IBAction)onUpgradeToFullVersion:(id)sender {
    [self showUpgradeModal:NO];
}

- (void)showUpgradeModal:(BOOL)naggy {
    if ( MacCustomizationManager.isUnifiedFreemiumBundle ) {
        UnifiedUpgrade* uu = [UnifiedUpgrade fromStoryboard];

        uu.naggy = naggy;
        
        [uu presentInNewWindow];
    }
    else {
        [UpgradeWindowController show:naggy ? 1 : 0];
    }
}

- (IBAction)onShowTipJar:(id)sender {
    TipJarViewController* vc = [TipJarViewController fromStoryboard];
    [vc presentInNewWindow];
}




- (void)onPreferencesChanged:(NSNotification*)notification {
    NSLog(@"AppDelegate::Preferences Have Changed Notification Received... Resetting Clipboard Clearing Tasks");

    [self initializeClipboardWatchingTask];
    [self showHideSystemStatusBarIcon];
}

- (void)applicationWillBecomeActive:(NSNotification *)notification {

    [self initializeClipboardWatchingTask];
}

- (void)initializeClipboardWatchingTask {
    [self killClipboardWatchingTask];
    
    if(Settings.sharedInstance.clearClipboardEnabled) {
        [self startClipboardWatchingTask];
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {

    [self killClipboardWatchingTask];
}

- (void)startClipboardWatchingTask {

    self.currentClipboardVersion = -1;
    
    self.clipboardChangeWatcher = [NSTimer scheduledTimerWithTimeInterval:0.5f
                                     target:self
                                   selector:@selector(checkClipboardForChangesAndNotify)
                                   userInfo:nil
                                    repeats:YES];

    





}

- (void)killClipboardWatchingTask {

    
    self.currentClipboardVersion = -1;
    
    if(self.clipboardChangeWatcher != nil) {
        [self.clipboardChangeWatcher invalidate];
        self.clipboardChangeWatcher = nil;
    }
}

- (void)checkClipboardForChangesAndNotify {
    
    
    if(self.currentClipboardVersion == -1) { 
        self.currentClipboardVersion = NSPasteboard.generalPasteboard.changeCount;
    }
    if(self.currentClipboardVersion != NSPasteboard.generalPasteboard.changeCount) {
        [self onStrongboxDidChangeClipboard];
        self.currentClipboardVersion = NSPasteboard.generalPasteboard.changeCount;
    }
    
    NSPasteboard* appCustomPasteboard = [NSPasteboard pasteboardWithName:kStrongboxPasteboardName];
    BOOL somethingOnAppCustomClipboard = [appCustomPasteboard dataForType:kDragAndDropExternalUti] != nil;
    if(somethingOnAppCustomClipboard && Settings.sharedInstance.clearClipboardEnabled) {
        [self scheduleClipboardClearTask];
    }
}

static NSInteger clipboardChangeCount;

- (void)onStrongboxDidChangeClipboard {
    NSLog(@"onApplicationDidChangeClipboard...");
    
    if ( Settings.sharedInstance.clearClipboardEnabled ) {
        clipboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
        NSLog(@"Clipboard Changed and Clear Clipboard Enabled... Recording Change Count as [%ld]", (long)clipboardChangeCount);
        [self scheduleClipboardClearTask];
    }
}

- (void)scheduleClipboardClearTask {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(Settings.sharedInstance.clearClipboardAfterSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        
        
        [self clearClipboardWhereAppropriate];
    });
}

- (void)clearClipboardWhereAppropriate {
    if ( clipboardChangeCount == NSPasteboard.generalPasteboard.changeCount ) {
        NSLog(@"General Clipboard change count matches after time delay... Clearing Clipboard");
        [NSPasteboard.generalPasteboard clearContents];
    }
    else {

    }
    
    [self clearAppCustomClipboard];
}

- (void)clearAppCustomClipboard {
    NSPasteboard* appCustomPasteboard = [NSPasteboard pasteboardWithName:kStrongboxPasteboardName];
    
    @synchronized (self) {
        if([appCustomPasteboard canReadItemWithDataConformingToTypes:@[kDragAndDropExternalUti]]) {
            [appCustomPasteboard clearContents];
            NSLog(@"Clearing Custom App Pasteboard!");
        }
    }
}

- (IBAction)onFloatOnTopToggle:(id)sender {
    Settings.sharedInstance.floatOnTop = !Settings.sharedInstance.floatOnTop;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kPreferencesChangedNotification object:nil];
}



- (IBAction)onImportFromCsvFile:(id)sender {
    [DBManagerPanel.sharedInstance show]; 

    NSString* loc = NSLocalizedString(@"mac_csv_file_must_contain_header_and_fields", @"The CSV file must contain a header row with at least one of the following fields:\n\n[%@, %@, %@, %@, %@, %@, %@]\n\nThe order of the fields doesn't matter.");

    NSString* message = [NSString stringWithFormat:loc, kCSVHeaderTitle, kCSVHeaderUsername, kCSVHeaderEmail, kCSVHeaderPassword, kCSVHeaderUrl, kCSVHeaderTotp, kCSVHeaderNotes];
   
    loc = NSLocalizedString(@"mac_csv_format_info_title", @"CSV Format");
    
    [MacAlerts info:loc
    informativeText:message
             window:NSApplication.sharedApplication.mainWindow
         completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestImportFile:[[CSVImporter alloc] init]];
        });
    }];
}

- (IBAction)onImportFromiCloudCsvFile:(id)sender {
    [self requestImportFile:[[iCloudImporter alloc] init]];
}

- (IBAction)onImportFromLastPassCsvFile:(id)sender {
    [self requestImportFile:[[LastPassImporter alloc] init]];
}

- (IBAction)onImport1Password1Pif:(id)sender {
    [DBManagerPanel.sharedInstance show]; 

    NSString* title = NSLocalizedString(@"1password_import_warning_title", @"1Password Import Warning");
    NSString* msg = NSLocalizedString(@"1password_import_warning_msg", @"The import process isn't perfect and some features of 1Password such as named sections are not available in Strongbox.\n\nIt is important to check that your entries as acceptable after you have imported.");
    
    [MacAlerts info:title
    informativeText:msg
             window:DBManagerPanel.sharedInstance.window
         completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestImportFile:[[OnePasswordImporter alloc] init]];
        });
    }];
}

- (IBAction)onImport1Password1Pux:(id)sender {










    [self requestImportFile:[[OnePassword1PuxImporter alloc] init]];


}

- (void)requestImportFile:(id<Importer>)importer {
    [DBManagerPanel.sharedInstance show]; 
    
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    NSString* loc = NSLocalizedString(@"mac_choose_file_import", @"Choose file to Import");
    [panel setTitle:loc];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setCanChooseFiles:YES];
    [panel setFloatingPanel:NO];
    panel.allowedFileTypes = importer.allowedFileTypes;
    
    NSInteger result = [panel runModal];
    if(result == NSModalResponseOK) {
        NSURL* url = panel.URLs.firstObject;
        if ( url ) {
            [self continueImportWithUrl:url importer:importer];
        }
    }
}

- (void)continueImportWithUrl:(NSURL*)url importer:(id<Importer>)importer {
    NSError* error;
    DatabaseModel* database = [importer convertWithUrl:url error:&error];
    
    if ( error ) {
        NSLog(@"🔴 %@", error.localizedDescription);
        [MacAlerts error:error window:DBManagerPanel.sharedInstance.window];
    }
    else {
        if ( !database ) {
            [MacAlerts info:NSLocalizedString(@"import_failed_title", @"🔴 Import Failed")
            informativeText:NSLocalizedString(@"import_failed_message", @"Strongbox could not import this file. Please check it is in the correct format.")
                     window:DBManagerPanel.sharedInstance.window
                 completion:nil];
            return;
        }
        else {
            [self addImportedDatabase:database];
        }
    }
}

- (void)addImportedDatabase:(DatabaseModel*)database {
    [MacAlerts info:NSLocalizedString(@"import_successful_title", @"✅ Import Successful")
    informativeText:NSLocalizedString(@"import_successful_message", @"Your import was successful! Now, let's set a strong master password and save your new Strongbox database.")
             window:DBManagerPanel.sharedInstance.window
         completion:^{
        [self setNewCkfsForImportedDatabase:database];
    }];
}

- (void)setNewCkfsForImportedDatabase:(DatabaseModel*)database {
    CreateFormatAndSetCredentialsWizard* wizard = [[CreateFormatAndSetCredentialsWizard alloc] initWithWindowNibName:@"ChangeMasterPasswordWindowController"];
    
    NSString* loc = NSLocalizedString(@"mac_please_enter_master_credentials_for_this_database", @"Please Enter the Master Credentials for this Database");
    wizard.titleText = loc;
    wizard.initialDatabaseFormat = kKeePass4;
    wizard.createSafeWizardMode = NO;
        
    [DBManagerPanel.sharedInstance.window beginSheet:wizard.window
                                   completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseOK) {
            [self onWizardDoneWithNewCkfs:wizard database:database];
        }
    }];
}

- (void)onWizardDoneWithNewCkfs:(CreateFormatAndSetCredentialsWizard*)wizard database:(DatabaseModel*)database {
    NSError* error;
    
    CompositeKeyFactors* ckf = [wizard generateCkfFromSelectedFactors:DBManagerPanel.sharedInstance.contentViewController
                                                                error:&error];
    
    if ( ckf ) {
        database.ckfs = ckf;
        
        DocumentController* dc = DocumentController.sharedDocumentController;
        [dc serializeAndAddDatabase:database
                             format:database.originalFormat
                    keyFileBookmark:wizard.selectedKeyFileBookmark
                      yubiKeyConfig:wizard.selectedYubiKeyConfiguration];
    }
    else {
        [MacAlerts error:error window:DBManagerPanel.sharedInstance.window];
    }
}

- (BOOL)shouldWaitForUpdatesOrSyncsToFinish {
    BOOL asyncUpdatesInProgress = [MacDatabasePreferences.allDatabases anyMatch:^BOOL(MacDatabasePreferences * _Nonnull obj) {
        return obj.asyncUpdateId != nil;
    }];

    return asyncUpdatesInProgress || MacSyncManager.sharedInstance.syncInProgress;
}

- (void)closeAllDatabases {
    NSArray* docs = DocumentController.sharedDocumentController.documents;
    NSMutableArray* mainWindows = [docs map:^id _Nonnull(id  _Nonnull obj, NSUInteger idx) {
        Document* doc = obj;
        NSWindowController* wc = (NSWindowController*)doc.windowControllers.firstObject;
        return wc.window;
    }].mutableCopy;

    for ( NSWindow* window in mainWindows ) {
        [window close];
    }
}

- (IBAction)onSystemTrayQuitStrongbox:(id)sender {
    self.explicitQuitRequest = YES;
    [NSApplication.sharedApplication terminate:nil];
}

- (void)onLogoutRestartOrShutdown:(NSNotification *)notification {
    NSLog(@"✅ onLogoutRestartOrShutdown...");
    
    
    
    
    
    
    self.explicitQuitRequest = YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    BOOL explicit = self.explicitQuitRequest;
    self.explicitQuitRequest = NO; 

    if ( Settings.sharedInstance.configuredAsAMenuBarApp && !Settings.sharedInstance.quitTerminatesProcessEvenInSystemTrayMode ) {
        if ( !explicit ) {
            NSLog(@"✅ applicationShouldTerminate => No - Closing all windows instead");

            [self closeAllDatabases];
            
            [DBManagerPanel.sharedInstance close];
            
            return NSTerminateCancel;
        }
    }
        
    [self stopRefreshOtpTimer];
    
    if ( [self shouldWaitForUpdatesOrSyncsToFinish] ) {
        
        
        [DBManagerPanel.sharedInstance show];
        
        [macOSSpinnerUI.sharedInstance show:NSLocalizedString(@"macos_quitting_finishing_sync", @"Quitting - Finishing Sync...")
                             viewController:DBManagerPanel.sharedInstance.contentViewController];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForAllSyncToFinishThenTerminate];
        });
    
        NSLog(@"✅ applicationShouldTerminate? => Yes, but later finish sync first");

        return NSTerminateLater;
    }
    else {
        NSLog(@"✅ applicationShouldTerminate? => Yes, immediately");

        return NSTerminateNow;
    }
}

- (void)waitForAllSyncToFinishThenTerminate {
    if ( [self shouldWaitForUpdatesOrSyncsToFinish] ) {

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1. * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForAllSyncToFinishThenTerminate];
        });
    }
    else {
        [macOSSpinnerUI.sharedInstance dismiss];

        NSLog(@"waitForAllSyncToFinishThenTerminate - All Syncs Done - Quitting app.");
        [NSApplication.sharedApplication replyToApplicationShouldTerminate:NSTerminateNow];
    }
}

- (void)onContactSupport:(id)sender {
    NSURL* launchableUrl = [NSURL URLWithString:@"https:
    
    if (@available(macOS 10.15, *)) {
        [[NSWorkspace sharedWorkspace] openURL:launchableUrl
                                 configuration:NSWorkspaceOpenConfiguration.configuration
                             completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
            if ( error ) {
                NSLog(@"Launch URL done. Error = [%@]", error);
            }
        }];
    }
    else {
        [[NSWorkspace sharedWorkspace] openURL:launchableUrl];
    }
}

- (IBAction)onAppPreferences:(id)sender {
    [AppPreferencesWindowController.sharedInstance showWithTab:AppPreferencesTabGeneral];
}

- (void)clearAsyncUpdateIdsAndEphemeralOfflineFlags {
    for (MacDatabasePreferences* preferences in MacDatabasePreferences.allDatabases) {
        preferences.asyncUpdateId = nil;
        preferences.userRequestOfflineOpenEphemeralFlagForDocument = NO;
    }
}

- (void)startRefreshOtpTimer {
    NSLog(@"startRefreshOtpTimer");
    
    if(self.timerRefreshOtp == nil) {
        self.timerRefreshOtp = [NSTimer timerWithTimeInterval:1.0f target:self selector:@selector(publishTotpUpdateNotification) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timerRefreshOtp forMode:NSRunLoopCommonModes];
    }
}

- (void)stopRefreshOtpTimer {
    NSLog(@"stopRefreshOtpTimer");
    
    if(self.timerRefreshOtp) {
        [self.timerRefreshOtp invalidate];
        self.timerRefreshOtp = nil;
    }
}

- (void)publishTotpUpdateNotification {
    [NSNotificationCenter.defaultCenter postNotificationName:kTotpUpdateNotification object:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return !Settings.sharedInstance.showSystemTrayIcon && Settings.sharedInstance.quitStrongboxOnAllWindowsClosed;
}

- (IBAction)onDumpXml:(id)sender {
    NSOpenPanel* openPanel = NSOpenPanel.openPanel;
    if ( [openPanel runModal] == NSModalResponseOK ) {
        NSData* data = [NSData dataWithContentsOfURL:openPanel.URL];
        
        MacAlerts *a = [[MacAlerts alloc] init];
        NSString* password = [a input:@"Password" defaultValue:@"" allowEmpty:YES];

        NSString* xml = [Serializator expressToXml:data password:password];
        
        NSLog(@"XML Dump: \n%@", xml);
    }
}

- (void)onProStatusChanged:(id)param {
    NSLog(@"✅ AppDelegate: Pro Status Changed!");

    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [self bindFreeOrProStatus];
    });
}

- (void)bindFreeOrProStatus {
    if ( MacCustomizationManager.isAProBundle || ProUpgradeIAPManager.sharedInstance.isLegacyLifetimeIAPPro ) { 
        [self removeMenuItem:kTopLevelMenuItemTagStrongbox action:@selector(onUpgradeToFullVersion:)];
    }
    
    if ( !MacCustomizationManager.supportsTipJar ) {
        [self removeMenuItem:kTopLevelMenuItemTagStrongbox action:@selector(onShowTipJar:)];
    }
    
    NSMenu* topLevelMenuItem = [NSApplication.sharedApplication.mainMenu itemWithTag:kTopLevelMenuItemTagStrongbox].submenu;
    if ( topLevelMenuItem ) {
        NSUInteger index = [topLevelMenuItem.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return obj.action == @selector(onAbout:);
        }];

        if( index != NSNotFound) {
            NSMenuItem* menuItem = [topLevelMenuItem itemAtIndex:index];
            NSString* fmt = Settings.sharedInstance.isPro ? NSLocalizedString(@"prefs_vc_app_version_info_pro_fmt", @"About Strongbox Pro %@") : NSLocalizedString(@"prefs_vc_app_version_info_none_pro_fmt", @"About Strongbox %@");
            menuItem.title = [NSString stringWithFormat:fmt, [Utils getAppVersion]];
        }
        
        index = [topLevelMenuItem.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return obj.action == @selector(onUpgradeToFullVersion:);
        }];

        if( index != NSNotFound) {
            NSMenuItem* menuItem = [topLevelMenuItem itemAtIndex:index];
            NSString* fmt = Settings.sharedInstance.isPro ? NSLocalizedString(@"upgrade_vc_change_my_license", @"Change My License...") : NSLocalizedString(@"mac_upgrade_button_title", @"Upgrade");
            menuItem.title = [NSString stringWithFormat:fmt, [Utils getAppVersion]];
        }
    }
}

@end
