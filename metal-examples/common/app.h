// Shared boilerplate for the Metal examples: window creation, app lifecycle,
// runtime shader compilation, and an FPS counter. Each example is a single
// translation unit that includes this header, defines an MTKViewDelegate
// renderer, and calls RunMetalApp().
#pragma once

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include <cstdio>

@interface MetalAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation MetalAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp activateIgnoringOtherApps:YES];
}
@end

// Compiles Metal Shading Language source at runtime so each example ships as
// one file with its shaders embedded. Production apps precompile .metallib.
static id<MTLLibrary> CompileLibrary(id<MTLDevice> device, const char *source) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:@(source)
                                                  options:nil
                                                    error:&error];
    if (!library) {
        fprintf(stderr, "Shader compile error:\n%s\n",
                error.localizedDescription.UTF8String);
    }
    return library;
}

struct FPSCounter {
    double lastTime = 0;
    int frames = 0;

    void tick(NSWindow *window, NSString *baseTitle) {
        frames++;
        double now = CACurrentMediaTime();
        if (lastTime == 0) lastTime = now;
        if (now - lastTime >= 1.0) {
            double fps = frames / (now - lastTime);
            window.title = [NSString stringWithFormat:@"%@ — %.0f fps", baseTitle, fps];
            frames = 0;
            lastTime = now;
        }
    }
};

typedef NSObject<MTKViewDelegate> *(^RendererFactory)(MTKView *view);

static int RunMetalApp(NSString *title, CGFloat width, CGFloat height,
                       RendererFactory makeRenderer) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        static MetalAppDelegate *appDelegate;
        appDelegate = [MetalAppDelegate new];
        NSApp.delegate = appDelegate;

        // A minimal menu bar so Cmd+Q works.
        NSMenu *menubar = [NSMenu new];
        NSMenuItem *appMenuItem = [NSMenuItem new];
        [menubar addItem:appMenuItem];
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;
        NSApp.mainMenu = menubar;

        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        static NSWindow *window;
        window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
        window.releasedWhenClosed = NO;
        window.title = title;
        [window center];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "Metal is not supported on this machine.\n");
            return 1;
        }
        printf("GPU: %s\n", device.name.UTF8String);

        MTKView *view = [[MTKView alloc] initWithFrame:frame device:device];
        view.preferredFramesPerSecond = 120; // ProMotion displays run the full 120Hz

        // MTKView.delegate is weak — hold a strong reference for the app's lifetime.
        static NSObject<MTKViewDelegate> *renderer;
        renderer = makeRenderer(view);
        if (!renderer) return 1;
        view.delegate = renderer;

        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [NSApp run];
    }
    return 0;
}
