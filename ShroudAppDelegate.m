//
//  ShroudAppDelegate.m
//  Shroud
//
//  Created by Nicholas Riley on 2/19/10.
//  Copyright 2010 Nicholas Riley. All rights reserved.
//

#import <SFBCrashReporter/SFBCrashReporter.h>

#import "ShroudAppDelegate.h"
#import "ShroudNonactivatingView.h"
#import "ShroudMenuBarView.h"
#import "ShroudPreferencesController.h"
#import "NJRHotKey.h"
#import "NJRHotKeyManager.h"

#include <Carbon/Carbon.h>

static void ShroudGetScreenAndMenuBarFrames(NSRect *screenFrame, NSRect *menuBarFrame) {
    NSScreen *mainScreen = [NSScreen mainScreen];
    *screenFrame = *menuBarFrame = [mainScreen frame];
    NSRect visibleFrame = [mainScreen visibleFrame];
    CGFloat menuBarHeight = visibleFrame.size.height + visibleFrame.origin.y;

    menuBarFrame->origin.y += menuBarHeight;
    menuBarFrame->size.height -= menuBarHeight;
}

@implementation ShroudAppDelegate

- (void)setUp;
{
    // Place Shroud behind the frontmost application at launch.
    ProcessSerialNumber frontProcess;
    GetFrontProcess(&frontProcess);
    [NSApp unhideWithoutActivation];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidChangeScreenParameters:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:NSApp];

    // Bind the background color of windows & the Dock icon to the default.
    NSUserDefaultsController *userDefaultsController = [NSUserDefaultsController sharedUserDefaultsController];
    NSDictionary *colorBindingOptions = [NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:NSValueTransformerNameBindingOption];
    NSString *colorBindingKeyPath = [@"values." stringByAppendingString:ShroudBackdropColorPreferenceKey];

    NSRect screenFrame, menuBarFrame;
    ShroudGetScreenAndMenuBarFrames(&screenFrame, &menuBarFrame);

    // Create screen panel.
    screenPanel = [[NSPanel alloc] initWithContentRect:screenFrame
					     styleMask:NSBorderlessWindowMask | NSNonactivatingPanelMask
					       backing:NSBackingStoreBuffered
						 defer:NO];

    [screenPanel bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];
    [screenPanel setHasShadow:NO];

    [screenPanel setCollectionBehavior:
     (1 << 3 /*NSWindowCollectionBehaviorTransient*/) |
     (1 << 6 /*NSWindowCollectionBehaviorIgnoresCycle*/)];

    ShroudNonactivatingView *view = [[[ShroudNonactivatingView alloc] initWithFrame:[screenPanel frame]] autorelease];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    [screenPanel setContentView:view];

    [screenPanel orderFront:nil];

    // Create menu bar panel.
    menuBarPanel = [[ShroudMenuBarPanel alloc] initWithContentRect:menuBarFrame
                                                         styleMask:NSBorderlessWindowMask | NSNonactivatingPanelMask
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];

    [menuBarPanel bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];
    [menuBarPanel setHasShadow:NO];

    [menuBarPanel setCollectionBehavior:
     (1 << 3 /*NSWindowCollectionBehaviorTransient*/) |
     (1 << 6 /*NSWindowCollectionBehaviorIgnoresCycle*/)];

    [menuBarPanel setIgnoresMouseEvents:YES];
    [menuBarPanel setLevel:NSStatusWindowLevel + 1];

    ShroudMenuBarView *menuBarView = [[[ShroudMenuBarView alloc] initWithFrame:[menuBarPanel frame]] autorelease];
    [menuBarView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    [menuBarPanel setContentView:menuBarView];

    // Note: the menuBarView itself reacts to internal triggers on showing/hiding the menu bar (menu tracking & mouse entry/exit).  The visibility controller reacts to external triggers (full screen mode and keyboard control).
    ShroudMenuBarVisibilityController *menuBarVisibilityController = [[ShroudMenuBarVisibilityController alloc] initWithWindow:menuBarPanel];
    [menuBarVisibilityController bind:@"shouldCoverMenuBar" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:ShroudShouldCoverMenuBarPreferenceKey] options:nil];

    // Create dock tile.
    NSDockTile *dockTile = [NSApp dockTile];
    dockTileView = [[ShroudDockTileView alloc] initWithFrame:
                    NSMakeRect(0, 0, dockTile.size.width, dockTile.size.height)];
    [dockTile setContentView:dockTileView];
    [dockTileView bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];

    // To avoid menubar flashing, we launch as a UIElement and transform ourselves when we're finished.
    ProcessSerialNumber currentProcess = { 0, kCurrentProcess };
    TransformProcessType(&currentProcess, kProcessTransformToForegroundApplication);

    SetFrontProcessWithOptions(&frontProcess, 0);

    // Register for shortcut changes.
    NSDictionary *hotKeyBindingOptions = [NSDictionary dictionaryWithObjectsAndKeys:@"NJRDictionaryToHotKeyTransformer", NSValueTransformerNameBindingOption,
        [NSNumber numberWithBool:YES], NSAllowsNullArgumentBindingOption,
        [NJRHotKey noHotKey], NSNullPlaceholderBindingOption,
        nil];
    // XXX whichever of these is first, the set method gets invoked twice at startup - why?
    [self bind:@"focusFrontmostApplicationShortcut" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:FocusFrontmostApplicationShortcutPreferenceKey] options:hotKeyBindingOptions];
    [self bind:@"focusFrontmostWindowShortcut" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:FocusFrontmostWindowShortcutPreferenceKey] options:hotKeyBindingOptions];

    // Check for and send crash reports.
    // (Without the delay, the crash reporter window is in front but the rest of Shroud, such as its menubar window, isn't, and the formerly frontmost app's menubar doesn't even respond to clicks.)
    [SFBCrashReporter performSelector:@selector(checkForNewCrashes) withObject:nil afterDelay:0.01];
}

#pragma mark actions

static ProcessSerialNumber frontProcess;

- (void)restoreFrontProcessWindowOnly:(NSNumber *)windowOnly;
{
    SetFrontProcessWithOptions(&frontProcess, [windowOnly boolValue] ? kSetFrontProcessFrontWindowOnly : 0);
}

- (void)focusFrontmostApplicationWindowOnly:(BOOL)windowOnly;
{
    if ([NSApp isActive])
        return;

    GetFrontProcess(&frontProcess);

    if (windowOnly) {
        [NSApp unhideWithoutActivation];
        [NSApp activateIgnoringOtherApps:YES];
    } else {
        BOOL wasHidden = [NSApp isHidden];
        [NSApp unhideWithoutActivation];
        if (!wasHidden) {
            SetFrontProcessWithOptions(&frontProcess, 0);
            return;
        }
    }
    // XXX can we get rid of this delay by using Carbon for unhiding ourself?
    [self performSelector:@selector(restoreFrontProcessWindowOnly:) withObject:[NSNumber numberWithBool:windowOnly] afterDelay: 0.05];
}

- (IBAction)focusFrontmostApplication:(id)sender;
{
    [self focusFrontmostApplicationWindowOnly:NO];
}

- (IBAction)focusFrontmostWindow:(id)sender;
{
    [self focusFrontmostApplicationWindowOnly:YES];
}

- (IBAction)orderFrontAboutPanel:(id)sender;
{
    NSRect bounds = [dockTileView bounds];
    NSBitmapImageRep *imageRep = [dockTileView bitmapImageRepForCachingDisplayInRect:bounds];
    [dockTileView cacheDisplayInRect:bounds toBitmapImageRep:imageRep];
    NSImage *image = [[NSImage alloc] init];
    [image addRepresentation: imageRep];

    [NSApp orderFrontStandardAboutPanelWithOptions:
     [NSDictionary dictionaryWithObject:image forKey:@"ApplicationIcon"]];
    [image release];
}

- (IBAction)orderFrontPreferencesPanel:(id)sender;
{
    [[ShroudPreferencesController sharedPreferencesController] showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark systemwide shortcut support

- (void)setShortcutWithPreferenceKey:(NSString *)preferenceKey hotKey:(NJRHotKey *)hotKey action:(SEL)action;
{
    NJRHotKeyManager *hotKeyManager = [NJRHotKeyManager sharedManager];
    if ([hotKeyManager addShortcutWithIdentifier:preferenceKey hotKey:hotKey target:self action:action])
        return;

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:preferenceKey];
    NSRunAlertPanel(NSLocalizedString(@"Can't reserve shortcut", "Hot key set failure"),
                    NSLocalizedString(@"Shroud was unable to reserve the shortcut %@. Please select another in Shroud's Preferences.", "Hot key set failure"), nil, nil, nil, [hotKey keyGlyphs]);
    [self performSelector:@selector(orderFrontPreferencesPanel:) withObject:nil afterDelay:0.1];
}

- (void)setFocusFrontmostApplicationShortcut:(NJRHotKey *)hotKey;
{
    [self setShortcutWithPreferenceKey:FocusFrontmostApplicationShortcutPreferenceKey hotKey:hotKey action:@selector(focusFrontmostApplication:)];
}

- (void)setFocusFrontmostWindowShortcut:(NJRHotKey *)hotKey;
{
    [self setShortcutWithPreferenceKey:FocusFrontmostWindowShortcutPreferenceKey hotKey:hotKey action:@selector(focusFrontmostWindow:)];
}

// make KVC happy
- (NJRHotKey *)focusFrontmostApplicationShortcut { return nil; }
- (NJRHotKey *)focusFrontmostWindowShortcut { return nil; }

@end

@implementation ShroudAppDelegate (NSApplicationNotifications)

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification;
{
    // Migrate preferences from Focus if needed.
    const CFStringRef FocusApplicationID = CFSTR("net.sabi.Focus");
    CFArrayRef focusPreferenceKeys = CFPreferencesCopyKeyList(FocusApplicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (focusPreferenceKeys != NULL) {
        CFArrayRef shroudPreferenceKeys = CFPreferencesCopyKeyList(kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (shroudPreferenceKeys == NULL) {
            CFDictionaryRef focusPreferences = CFPreferencesCopyMultiple(focusPreferenceKeys, FocusApplicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFMutableDictionaryRef shroudPreferences = CFDictionaryCreateMutableCopy(NULL, CFDictionaryGetCount(focusPreferences) + 1, focusPreferences);
            CFRelease(focusPreferences);

            CFDictionarySetValue(shroudPreferences, CFSTR("ShroudHighestVersionRun"),
                                 CFDictionaryGetValue(shroudPreferences, CFSTR("FocusHighestVersionRun")));
            CFDictionaryRemoveValue(shroudPreferences, CFSTR("FocusHighestVersionRun"));
            CFPreferencesSetMultiple(shroudPreferences, NULL, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
            CFRelease(shroudPreferences);
        } else CFRelease(shroudPreferenceKeys);
        CFRelease(focusPreferenceKeys);
    }

    // Initialize preferences.
    NSUserDefaultsController *userDefaultsController = [NSUserDefaultsController sharedUserDefaultsController];

    [userDefaultsController setInitialValues:
     [NSDictionary dictionaryWithObject:[NSArchiver archivedDataWithRootObject:[NSColor colorWithCalibratedWhite:0.239 alpha:1.000]]
                                 forKey:ShroudBackdropColorPreferenceKey]];

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    float currentVersion = [[[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey] floatValue];
    float priorVersion = [userDefaults floatForKey:@"ShroudHighestVersionRun"];
    if (priorVersion < currentVersion)
        [userDefaults setFloat:currentVersion forKey:@"ShroudHighestVersionRun"];
    if (priorVersion < 7. || priorVersion == 8.) {
        NSString *helpBookName = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleHelpBookName"];
        [[NSHelpManager sharedHelpManager] openHelpAnchor:@"introduction" inBook:helpBookName];
    }

    [NSApp hide:nil];

    [self performSelector:@selector(setUp) withObject:nil afterDelay:0];
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification;
{
    NSRect screenFrame, menuBarFrame;
    ShroudGetScreenAndMenuBarFrames(&screenFrame, &menuBarFrame);

    [screenPanel setFrame:screenFrame display:YES];
    [menuBarPanel shroudSetFrame:menuBarFrame display:YES];
}

@end

@implementation ShroudAppDelegate (NSMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
{
    SEL action = [menuItem action];

    if (action == @selector(focusFrontmostApplication:) ||
        action == @selector(focusFrontmostWindow:))
        return ![NSApp isActive];

    return YES;
}

@end
