/**
 * Paintbrush
 * Copyright (C) 2007-2019  Michael Schreiber
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */


#import "SWImageTools.h"
#import "SWSizeWindowController.h"
#import "SWDocument.h"


// The T-shirt preset must match SWJNShirt.canvasSize (12 x 16 in at 50 px per inch)
// Half size canvases export at 2x with crisp pixels, so they suit a mouse and still fill a reel.
// A nil label marks a separator between groups.
static NSString *sizeMenuLabels[] = {
	@"Instagram Reel 9:16 (1080 × 1920)", @"Instagram Reel 9:16, half size (540 × 960)",
	@"Instagram Portrait 3:4 (1080 × 1440)", @"Instagram Portrait 4:5 (1080 × 1350)",
	@"Instagram Square 1:1 (1080 × 1080)", @"Landscape 16:9 (1920 × 1080)",
	nil,
	@"T-Shirt Print (12 × 16 in)",
	nil,
	@"640_480", @"800_600", @"1024_768", @"1280_1024" };
static NSUInteger sizeMenuWidths[] = { 1080, 540, 1080, 1080, 1080, 1920, 0, 600, 0, 640, 800, 1024, 1280 };
static NSUInteger sizeMenuHeights[] = { 1920, 960, 1440, 1350, 1080, 1080, 0, 800, 0, 480, 600, 768, 1024 };
static NSUInteger numItems = sizeof(sizeMenuWidths) / sizeof(sizeMenuWidths[0]);
// Preset menu items are tagged with their index plus this, so separators don't shift anything
static NSInteger presetTagOffset = 100;


@implementation SWSizeWindowController

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void)windowDidLoad
{
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(textDidChange:)
												 name:NSControlTextDidChangeNotification
											   object:nil];
	
	// Read the defaults for width and height
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	NSNumber *width = [defaults objectForKey:@"HorizontalSize"];
	NSNumber *height = [defaults objectForKey:@"VerticalSize"];
	[widthField setIntValue:[width intValue]];
	[heightField setIntValue:[height intValue]];
    
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterNoStyle];
    
    [widthField setFormatter:formatter];
    [heightField setFormatter:formatter];
	
	// Populate the sizeButton
	[sizeButton removeAllItems];
	
	// Add the custom items to the popup
	NSMenu *buttonMenu = [sizeButton menu];
	clipboard = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"From Clipboard", @"Size of the image copied to the clipboard")
										   action:@selector(changeSizeButton:)
									keyEquivalent:@""];
	[buttonMenu addItem:clipboard];
	[buttonMenu addItemWithTitle:NSLocalizedString(@"Custom", @"Custom size")
						  action:@selector(changeSizeButton:)
				   keyEquivalent:@""];
	[buttonMenu addItem:[NSMenuItem separatorItem]];
	
	// Add the size presets
	NSUInteger cnt;
	for (cnt = 0; cnt < numItems; cnt++) {
		if (!sizeMenuLabels[cnt]) {
			[buttonMenu addItem:[NSMenuItem separatorItem]];
			continue;
		}
		NSMenuItem *item = [buttonMenu addItemWithTitle:NSLocalizedString(sizeMenuLabels[cnt], nil)
												 action:@selector(changeSizeButton:)
										  keyEquivalent:@""];
		[item setTag:presetTagOffset + cnt];
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification 
														object:nil];
}


// If the user changes the size of the image using the NSPopUpButton,
// change the two text fields to stay synchronized with it
- (IBAction)changeSizeButton:(id)sender
{
    auto to_int = [](NSUInteger input) -> int { return [[NSNumber numberWithInteger:input] intValue]; };
    
	if ([sizeButton selectedItem] == clipboard) {
		NSData *data = [SWImageTools readImageFromPasteboard:[NSPasteboard generalPasteboard]];
		if (data) {
			NSBitmapImageRep *temp = [[NSBitmapImageRep alloc] initWithData:data];
			[widthField setIntValue:[temp size].width];
			[heightField setIntValue:[temp size].height];
		}
	} else {
		NSInteger index = [[sizeButton selectedItem] tag] - presetTagOffset;
		if (index >= 0 && index < (NSInteger)numItems && sizeMenuLabels[index]) {
			// The user selected one of the size presets
			[widthField setIntValue:to_int(sizeMenuWidths[index])];
			[heightField setIntValue:to_int(sizeMenuHeights[index])];
		}
	}
}


-(BOOL) validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem == clipboard)
        return [SWImageTools readImageFromPasteboard:[NSPasteboard generalPasteboard]] != nil;
    return YES;
}


// Each time the user types in the width or height field, check to see if it's
// one of the preset values in the popup button
- (void)textDidChange:(NSNotification *)aNotification
{
	NSInteger width = [widthField integerValue];
	NSInteger height = [heightField integerValue];
	BOOL isFound = NO;
	
	NSUInteger cnt;
	for (cnt = 0; cnt < numItems; cnt++) {
		if (sizeMenuLabels[cnt] && width == sizeMenuWidths[cnt] && height == sizeMenuHeights[cnt]) {
			[sizeButton selectItemWithTag:presetTagOffset + cnt];
			isFound = YES;
			break;
		}
	}
	
	if (!isFound) {
		[sizeButton selectItemWithTitle:@"Custom"];
	}
}


// After they click OK or Cancel
- (IBAction)endSheet:(id)sender
{
	if ([sender tag] == NSModalResponseOK) {
		if ([widthField integerValue] > 0 && [heightField integerValue] > 0) {
			
			// Save entered values as defaults
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			NSNumber *width = [NSNumber numberWithInt:[widthField intValue]];
			NSNumber *height = [NSNumber numberWithInt:[heightField intValue]];
			[defaults setObject:width forKey:@"HorizontalSize"];
			[defaults setObject:height forKey:@"VerticalSize"];
			
			[[self window] orderOut:sender];
			[NSApp endSheet:[self window] returnCode:NSModalResponseOK];
		} else {
			NSBeep();
		}
	} else {
		// They clicked cancel
		[[self window] orderOut:sender];
		[NSApp endSheet:[self window] returnCode:NSModalResponseCancel];
	}	
}


- (NSInteger)width
{
	return [widthField integerValue];
}


- (NSInteger)height
{
	return [heightField integerValue];
}


- (void)setWidth:(NSInteger)newWidth
{
	[widthField setIntegerValue:newWidth];
}


- (void)setHeight:(NSInteger)newHeight
{
	[heightField setIntegerValue:newHeight];
}


@end
