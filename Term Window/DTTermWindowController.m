//  DTTermWindowController.m
//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "DTTermWindowController.h"

#import "DTAppController.h"
#import "DTCommandFieldEditor.h"
#import "DTResultsView.h"
#import "DTResultsTextView.h"
#import "DTRunManager.h"
#import "DTShellUtilities.h"
#import "iTerm2.h"
#import "Terminal.h"

static void * DTPreferencesContext = &DTPreferencesContext;

static NSString *DTAppleScriptString(NSString *string) {
	NSString *escapedString = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
	escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
	escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
	escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
	return [NSString stringWithFormat:@"\"%@\"", escapedString];
}

@implementation DTTermWindowController

@synthesize workingDirectory, selectedURLs, command, runs, runsController;

- (instancetype)init {
	if((self = [super initWithWindowNibName:@"TermWindow"])) {
		[self setShouldCascadeWindows:NO];
		
		self.command = @"";
		self.runs = [NSMutableArray array];
		
		NSUserDefaultsController *sdc = [NSUserDefaultsController sharedUserDefaultsController];
		[sdc addObserver:self forKeyPath:@"values.DTTextColor" options:0 context:DTPreferencesContext];
		[sdc addObserver:self forKeyPath:@"values.DTFontName" options:0 context:DTPreferencesContext];
		[sdc addObserver:self forKeyPath:@"values.DTFontSize" options:0 context:DTPreferencesContext];
	}
	
	return self;
}

- (void)windowDidLoad {
	NSPanel* panel = (NSPanel*)[self window];
	[panel setHidesOnDeactivate:NO];
	
	// Bind the results text storage up
	[resultsTextView bind:@"resultsStorage"
				 toObject:runsController
			  withKeyPath:@"selection.resultsStorage"
				  options:nil];
	
	// Swap in the results view for its placeholder
	[resultsView setFrame:[placeholderForResultsView frame]];
	[placeholderForResultsView removeFromSuperview];
	[[[self window] contentView] addSubview:resultsView];
	
	// Remove the excess action menu items if we're showing the dock icon
    if( ![[NSBundle mainBundle] objectForInfoDictionaryKey:@"LSUIElement"] ) {
        // It's not a UIElement, i.e. the dock icon is shown
        // Remove the menu items up to the last separator
        BOOL wasSeparator = NO;
        do {
            NSMenuItem* lastItem = [actionMenu itemAtIndex:([actionMenu numberOfItems]-1)];
            wasSeparator = [lastItem isSeparatorItem];
            [actionMenu removeItem:lastItem];
        } while(!wasSeparator && [actionMenu numberOfItems]);
    }
}

- (id)windowWillReturnFieldEditor:(NSWindow*)window toObject:(id)anObject {
	if(window != [self window])
		return nil;
	if(anObject != commandField)
		return nil;
	
	if(!commandFieldEditor) {
		commandFieldEditor = [[DTCommandFieldEditor alloc] initWithController:self];
	}
	
	return commandFieldEditor;
}

- (void)setCommand:(NSString*)newCommand {
	command = newCommand;
	
	id firstResponder = [[self window] firstResponder];
	if([firstResponder isKindOfClass:[DTCommandFieldEditor class]]) {
		// We may be editing.  Make sure the field editor reflects the change too.
		NSTextStorage* textStorage = [firstResponder textStorage];
		[textStorage replaceCharactersInRange:NSMakeRange(0, [textStorage length]) 
								   withString:(newCommand ? newCommand : @"")];
	}
}


- (void)activateWithWorkingDirectory:(NSString*)wdPath
						   selection:(NSArray*)selection
						 windowFrame:(NSRect)frame {
	// Set the state variables
	self.workingDirectory = wdPath;
	self.selectedURLs = selection;
		
	// Hide window
	NSWindow* window = [self window];
	[window setAlphaValue:0.0];
	
	// Resize text view
	[resultsTextView minSize];
	// Select all of the command field
	[commandFieldEditor setSelectedRange:NSMakeRange(0, [[commandFieldEditor string] length])];
	[window makeFirstResponder:commandField];
    
    // desired width = 70% window width, with max window/screen width at 1680
    // 1680 = 22" is a good cap, anything above looks redicoulous on larger screens like 2560 = 29"
    NSScreen* mainScreen = [NSScreen mainScreen];
    CGFloat screenWidth = mainScreen.visibleFrame.size.width;
    CGFloat maxReasonableScreenWidth = 1680.0;
    CGFloat minWidth = 640.0;
    CGFloat maxWidth = fmin(maxReasonableScreenWidth,screenWidth)*0.7;
    CGFloat desiredWidth = fmax(fmin(frame.size.width*0.7, maxWidth), minWidth);
    
    // If no parent window; use main screen
	if(NSEqualRects(frame, NSZeroRect)) {
        frame = [mainScreen visibleFrame];
        desiredWidth = fmax(maxWidth, minWidth);
	}
	
	// Set frame according to parent window location
	NSRect newFrame = NSInsetRect(frame, (frame.size.width - desiredWidth) / 2.0, 0.0);
	newFrame.size.height = [window frame].size.height + [resultsTextView desiredHeightChange];
	newFrame.origin.y = frame.origin.y + frame.size.height - newFrame.size.height;
	[window setFrame:newFrame display:YES];
	
	[window makeKeyAndOrderFront:self];
	
	[NSAnimationContext beginGrouping];
	[[NSAnimationContext currentContext] setDuration:0.1f];
	[[window animator] setAlphaValue:1.0];
	[NSAnimationContext endGrouping];
}

- (void)deactivate {
	NSUInteger numRunsToKeep = (NSUInteger)[[NSUserDefaults standardUserDefaults] integerForKey:DTResultsToKeepKey];
	if(numRunsToKeep > 100)
		numRunsToKeep = 100;
	
	if([runs count] > numRunsToKeep) {
		// Delete non-running runs until we're below the threshold or are out of runs
		NSMutableArray* newRuns = [self.runs mutableCopy];
		
		unsigned i=0;
		while(([newRuns count] > numRunsToKeep) && (i < [newRuns count])) {
			DTRunManager* run = newRuns[i];
			if(run.task)
				i++;
			else
				[newRuns removeObjectAtIndex:i];								 
		}
		
		self.runs = newRuns;
	}
	
	
	[NSAnimationContext beginGrouping];
	[[NSAnimationContext currentContext] setDuration:0.1f];
	[[[self window] animator] setAlphaValue:0.0];
	[NSAnimationContext endGrouping];
	
	[[self window] performSelector:NSSelectorFromString(@"orderOut:")
						withObject:self
						afterDelay:0.11f];
}

- (void)windowDidResignKey:(NSNotification*)notification {
	if([notification object] != [self window])
		return;
	
	[self deactivate];
}

- (IBAction)insertSelection:(id) __unused sender {
	NSMutableArray* paths = [NSMutableArray arrayWithCapacity:[selectedURLs count]];
	for(NSString* urlString in self.selectedURLs) {
		NSURL* url = [NSURL URLWithString:urlString];
		if([url isFileURL]) {
			NSString* newPath = [url path];
			if([newPath hasPrefix:workingDirectory]) {
				newPath = [newPath substringFromIndex:[workingDirectory length]];
				if([newPath hasPrefix:@"/"])
					newPath = [newPath substringFromIndex:1];
			}
			[paths addObject:[escapedPath(newPath) mutableCopy]];
		}
	}
	
	[commandFieldEditor insertFiles:paths];
}
- (IBAction)insertSelectionFullPaths:(id) __unused sender {
	NSMutableArray* paths = [NSMutableArray arrayWithCapacity:[selectedURLs count]];
	for(NSString* urlString in self.selectedURLs) {
		NSURL* url = [NSURL URLWithString:urlString];
		if([url isFileURL]) {
			NSString* newPath = [url path];
			[paths addObject:[escapedPath(newPath) mutableCopy]];
		}
	}
	
	[commandFieldEditor insertFiles:paths];
}
- (IBAction)pullCommandFromResults:(id) __unused sender {
	id selection = [runsController selection];
	NSString* resultsCommand = [selection valueForKey:@"command"];
	if(resultsCommand) {
		// At this point, self.command is still the last executed command (?!), so we have to use
		// the length of [commandFieldEditor string] to reflect anything the user's typed since then
		// https://decimus.fogbugz.com/default.asp?11185
		[commandFieldEditor setSelectedRange:NSMakeRange(0, [[commandFieldEditor string] length])];
		[commandFieldEditor insertText:resultsCommand];
	}
}
- (IBAction)executeCommand:(id) __unused sender {
	// Commit editing first
	if(![[self window] makeFirstResponder:[self window]])
		return;
	
	if(!self.command || ![self.command length])
		return;
	
    DTRunManager* runManager = [[DTRunManager alloc] initWithWD:self.workingDirectory
                                                      selection:self.selectedURLs
                                                        command:self.command];
    [runsController addObject:runManager];
}

- (NSString *)configuredTerminalPath {
	NSString *environmentPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"DTERM_TERM"];
	if([environmentPath length])
		return environmentPath;

	NSString *preferencePath = [[NSUserDefaults standardUserDefaults] stringForKey:DTTerminalPathKey];
	if([preferencePath length])
		return preferencePath;

	NSString *ghosttyPath = @"/Applications/Ghostty.app/Contents/MacOS/ghostty";
	if([[NSFileManager defaultManager] isExecutableFileAtPath:ghosttyPath])
		return ghosttyPath;

	return nil;
}

- (BOOL)executeCommandInConfiguredTerminal:(NSString *)terminalPath {
	if(![terminalPath length])
		return NO;

	if(![[NSFileManager defaultManager] isExecutableFileAtPath:terminalPath]) {
		NSLog(@"Configured terminal is not executable: %@", terminalPath);
		return NO;
	}

	if([[terminalPath lastPathComponent] caseInsensitiveCompare:@"ghostty"] == NSOrderedSame) {
		if([self executeCommandInRunningGhostty])
			return YES;

		// Without an existing Ghostty window, open the application normally.  Do
		// not use -e: Ghostty asks for confirmation before executing such commands.
		NSString *applicationPath = [[[terminalPath stringByDeletingLastPathComponent]
								 stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
		NSTask *task = [[NSTask alloc] init];
		[task setLaunchPath:@"/usr/bin/open"];
		[task setArguments:@[applicationPath]];

		@try {
			[task launch];
		}
		@catch (NSException *exception) {
			NSLog(@"Could not open Ghostty: %@", exception);
			return NO;
		}

		return YES;
	}

	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath:terminalPath];
	[task setCurrentDirectoryPath:self.workingDirectory];
	@try {
		[task launch];
	}
	@catch (NSException *exception) {
		NSLog(@"Could not launch configured terminal %@: %@", terminalPath, exception);
		return NO;
	}
	return YES;
}

- (BOOL)executeCommandInRunningGhostty {
	SBApplication *ghostty = [SBApplication applicationWithBundleIdentifier:@"com.mitchellh.ghostty"];
	if(![ghostty isRunning])
		return NO;

	NSString *terminalCommand = [NSString stringWithFormat:@"cd %@", escapedPath(self.workingDirectory)];
	if([self.command length])
		terminalCommand = [terminalCommand stringByAppendingFormat:@"; %@", self.command];

	NSString *source = [NSString stringWithFormat:
		@"tell application id \"com.mitchellh.ghostty\"\n"
		 "\tset targetTerminal to focused terminal of selected tab of front window\n"
		 "\tinput text %@ to targetTerminal\n"
		 "\tsend key \"enter\" to targetTerminal\n"
		 "\tactivate window front window\n"
		 "\treturn \"true\"\n"
		 "end tell", DTAppleScriptString(terminalCommand)];
	NSDictionary *error = nil;
	NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
	NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
	if(!result) {
		NSLog(@"Could not send command to Ghostty: %@", error);
		return NO;
	}

	return [[result stringValue] boolValue];
}

- (IBAction)executeCommandInTerminal:(id) __unused sender {
	// Commit editing first
	if(![[self window] makeFirstResponder:[self window]])
		return;

	NSString *configuredTerminalPath = [self configuredTerminalPath];
	if([configuredTerminalPath length]) {
		[self executeCommandInConfiguredTerminal:configuredTerminalPath];
		return;
	}
	
	NSString* cdCommandString = [NSString stringWithFormat:@"cd %@", escapedPath(self.workingDirectory)];
	
	id iTerm = [SBApplication applicationWithBundleIdentifier:@"com.googlecode.iterm2"];
	if(!iTerm)
		iTerm = [SBApplication applicationWithBundleIdentifier:@"net.sourceforge.iTerm"]; // legacy iTerm
    
    // test for iTerms newer scripting bridge
    if(iTerm && [iTerm respondsToSelector:@selector(createWindowWithDefaultProfileCommand:)]) {
        iTerm2Window *window = [iTerm createWindowWithDefaultProfileCommand:nil];
        iTerm2Session *session = [window currentSession];
        
        int cnt = 0;
        while ([[session text] length] == 0) {
            if ( cnt++ > 100 ) {
                NSLog(@"timeout reached");
                break;
            }
            NSLog(@"wait for prompt...");
            [NSThread sleepForTimeInterval:0.01f];
        }
        
        // write text "cd ~/whatever"
        [session writeContentsOfFile:nil text:cdCommandString newline:true];
        
        // write text "thecommand"
        if ([self.command length] > 0) {
            [session writeContentsOfFile:nil text:self.command newline:true];
        }
        
        [iTerm activate];
    } else {
		TerminalApplication* terminal = (TerminalApplication *)[SBApplication applicationWithBundleIdentifier:@"com.apple.Terminal"];
		BOOL terminalAlreadyRunning = [terminal isRunning];
		
		TerminalWindow* frontWindow = [[terminal windows] firstObject];
		if(![frontWindow exists])
			frontWindow = nil;
		else
			frontWindow = [frontWindow get];
		
		TerminalTab* tab = nil;
		if(frontWindow) {
			if(!terminalAlreadyRunning) {
				tab = [[frontWindow tabs] firstObject];
			} else if(/*terminalUsesTabs*/false) {
				tab = [[[terminal classForScriptingClass:@"tab"] alloc] init];
				[[frontWindow tabs] addObject:tab];
			}
		}
		
		tab = [terminal doScript:cdCommandString in:tab];
        
        if ([self.command length] > 0) {
            [terminal doScript:self.command in:tab];
        }
		
		[terminal activate];
	}
}


- (void)cancelOperation:(id) __unused sender {
	[self deactivate];
}

- (IBAction)copyResultsToClipboard:(id) __unused sender {
//	[[NSSound soundNamed:@"Blow"] play];
	//	NSLog(@"Asked to copy results to clipboard");
	
	id selection = [runsController selection];
	NSTextStorage* resultsStorage = [selection valueForKey:@"resultsStorage"];
	if(!resultsStorage)
		return;
	
	NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:@[NSPasteboardTypeString] owner:self];
    [pb setString:[resultsStorage string] forType:NSPasteboardTypeString];
	
	[self deactivate];
}

- (IBAction)cancelCurrentCommand:(id)sender {
	NSArray* selection = [runsController selectedObjects];
	[selection makeObjectsPerformSelector:NSSelectorFromString(@"cancel:") withObject:sender];
}

- (void)requestWindowHeightChange:(CGFloat)dHeight {
	NSWindow* window = [self window];
	
	// Calculate new frame, ignoring window constraint
	NSRect windowFrame = [window frame];
	windowFrame.size.height += dHeight;
	windowFrame.origin.y -= dHeight;
	
	// Adjust bottom edge so it's on the screen
	NSScreen* screen = [window screen];
	NSRect screenRect = [screen visibleFrame];
	dHeight = windowFrame.origin.y - screenRect.origin.y;
	if(dHeight < 0.0) {
		windowFrame.size.height += dHeight;
		windowFrame.origin.y -= dHeight;
	}
	
	[window setFrame:windowFrame
			 display:YES
			 animate:YES];
}

- (NSArray*)completionsForPartialWord:(NSString*)partialWord
							isCommand:(BOOL)isCommand
				  indexOfSelectedItem:(NSInteger*)index
{
    UnusedParameter(index);
    
	BOOL allowFiles = (!isCommand || [partialWord hasPrefix:@"/"] || [partialWord hasPrefix:@"./"] || [partialWord hasPrefix:@"../"]);
	
	NSTask* task = [[NSTask alloc] init];
	[task setCurrentDirectoryPath:self.workingDirectory];
	[task setLaunchPath:@"/bin/bash"];
	[task setArguments:[DTRunManager argumentsToRunCommand:[NSString stringWithFormat:@"compgen -%@%@%@ %@",
															([[[DTRunManager shellPath] lastPathComponent] isEqualToString:@"bash"] ? @"a" : @""),
															(isCommand ? @"bc" : @""),
															(allowFiles ? @"df" : @""),
															partialWord]]];
	
	// Attach pipe to task's standard output
	NSPipe* newPipe = [NSPipe pipe];
	NSFileHandle* stdOut = [newPipe fileHandleForReading];
	[task setStandardOutput:newPipe];
	
	// Setting the accessibility flag gives us a sticky egid of 'accessibility', which seems to interfere with shells using .bashrc and whatnot.
	// We temporarily set our gid back before launching to work around this problem.
	// Case 8042: http://fogbugz.decimus.net/default.php?8042
    int egidResult = 0;
	gid_t savedEGID = getegid();
	egidResult = setegid(getgid());
    if (egidResult != 0)
        NSLog(@"WARNING: failed to set EGID");

	[task launch];

	egidResult = setegid(savedEGID);
    if (egidResult != 0)
        NSLog(@"WARNING: failed to set EGID");

	NSData* resultsData = [stdOut readDataToEndOfFile];
	NSString* results = [[NSString alloc] initWithData:resultsData encoding:NSUTF8StringEncoding];
	
	NSMutableSet* completionsSet = [NSMutableSet setWithArray:[results componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
	[completionsSet removeObject:@""];
	
	NSMutableArray* completions = [NSMutableArray arrayWithCapacity:[completionsSet count]];
	NSFileManager* fileManager = [NSFileManager defaultManager];
	for(__strong NSString* completion in completionsSet) {
		NSString* actualPath = ([completion hasPrefix:@"/"] ? completion : [workingDirectory stringByAppendingPathComponent:completion]);
		BOOL isDirectory = NO;
		if([fileManager fileExistsAtPath:actualPath isDirectory:&isDirectory] && isDirectory)
			completion = [completion stringByAppendingString:@"/"];
		
		[completions addObject:completion];
	}
	
	if(![completions count])
		return nil;
	
	[completions sortUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"length" ascending:YES],
									   [[NSSortDescriptor alloc] initWithKey:@"lowercaseString" ascending:YES]]];
	
	return completions;
}

#pragma mark font/color support

- (void)observeValueForKeyPath:(NSString *)keyPath
					  ofObject:(id)object
						change:(NSDictionary *)change
					   context:(void *)context {
	if(context != DTPreferencesContext){
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	if([keyPath isEqualToString:@"values.DTFontName"] || [keyPath isEqualToString:@"values.DTFontSize"]) {
		NSFont* newFont = [NSFont fontWithName:[defaults objectForKey:DTFontNameKey]
										  size:[defaults doubleForKey:DTFontSizeKey]];
		for(DTRunManager* run in runs)
			[run setDisplayFont:newFont];
	} else if([keyPath isEqualToString:@"values.DTTextColor"]) {
		NSColor* newColor = [NSKeyedUnarchiver unarchiveObjectWithData:[defaults objectForKey:DTTextColorKey]];
		for(DTRunManager* run in runs)
			[run setDisplayColor:newColor];
	}
	
	[[[self window] contentView] setNeedsDisplay:YES];
}

- (CGFloat)resultsCommandFontSize {
	return 10.0;
}

@end
