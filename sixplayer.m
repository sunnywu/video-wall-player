//
//  sixplayer -- 6 VLC videos, fullscreen 3x2 grid, controlled per-key, all start MUTED.
//
//  Drives the libVLC that ships inside /Applications/VLC.app (no separate install).
//  Each cell gets its own libvlc_media_player_t embedded into an on-screen NSView via
//  libvlc_media_player_set_nsobject() (VLC's documented macOS embed), then we seek and
//  mute it directly with the libVLC C API.
//
//  Key map (each video owns one home-row letter on the LEFT hand):
//       a s d f g h      = video 1..6 -> forward by SKIP seconds (default 10)
//       Shift + letter   = that video -> backward by SKIP seconds
//       Option + letter  = that video -> toggle mute (videos start muted)
//       q / Cmd-Q        = quit          Esc = show/hide the cheat sheet
//
//  Build+run via run.sh (which sets DYLD_LIBRARY_PATH / VLC_PLUGIN_PATH). The only
//  libVLC symbols used are declared here via extern, so the build is immune to
//  version-specific libvlc.h drift.
//
#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

/* --------------------------- libVLC C API (extern) --------------------------- */
typedef struct libvlc_instance_t      libvlc_instance_t;
typedef struct libvlc_media_t         libvlc_media_t;
typedef struct libvlc_media_player_t  libvlc_media_player_t;

extern libvlc_instance_t  *libvlc_new(int, char **);
extern void                libvlc_release(libvlc_instance_t *);
extern libvlc_media_t     *libvlc_media_new_path(libvlc_instance_t *, const char *);
extern void                libvlc_media_release(libvlc_media_t *);
extern libvlc_media_player_t *libvlc_media_player_new_from_media(libvlc_media_t *);
extern int   libvlc_media_player_play(libvlc_media_player_t *);
extern void  libvlc_media_player_release(libvlc_media_player_t *);
extern int64_t libvlc_media_player_get_time(libvlc_media_player_t *);
extern int   libvlc_media_player_set_time(libvlc_media_player_t *, int64_t);
extern int   libvlc_media_player_is_playing(libvlc_media_player_t *);
extern int   libvlc_media_player_get_state(libvlc_media_player_t *);
extern void  libvlc_media_player_set_nsobject(libvlc_media_player_t *, const void *);
extern int   libvlc_audio_get_mute(libvlc_media_player_t *);
extern void  libvlc_audio_set_mute(libvlc_media_player_t *, int);
extern void  libvlc_audio_toggle_mute(libvlc_media_player_t *);
extern void  libvlc_audio_set_volume(libvlc_media_player_t *, int);
extern const char *libvlc_get_version(void);

/* ---------------------------------- state ---------------------------------- */
#define NCELLS 6
#define COLS   3
#define ROWS   2

@interface CellView   : NSView @end   /* per-cell dark background; VLC embeds into its layer */
@interface OverlayView : NSView @end  /* full-screen top view; draws the cheat sheet */
@interface KeyWindow  : NSWindow @end /* borderless, can become key, captures the keyboard */
@interface AppDelegate : NSObject <NSApplicationDelegate> @end

struct Cell {
    int index;
    int letter;
    NSString *path;
    libvlc_media_t        *media;
    libvlc_media_player_t *player;
    CellView              *view;
    NSWindow              *window;
};
static struct Cell g_cells[NCELLS];
static NSArray *g_letters = nil;
static NSWindow       *g_window  = nil;
static NSWindow       *g_overlayWindow = nil;
static OverlayView    *g_overlay = nil;
static libvlc_instance_t *g_inst = nil;
static NSTimer        *g_tick    = nil;
static BOOL            g_cheat   = YES;
static long            SKIP_MS = 10000;
static int             g_argc = 0;
static char          **g_argv = NULL;

/* --------------------------------- helpers --------------------------------- */

static NSString *normPath(NSString *raw)
{
    NSString *p = [raw stringByExpandingTildeInPath];
    if ([p hasPrefix:@"/"]) return p;
    char cwd[1024];
    if (getcwd(cwd, sizeof cwd))
        return [NSString stringWithFormat:@"%s/%@", cwd, p];
    return [raw stringByExpandingTildeInPath];
}

static NSString *baseName(NSString *p)
{
    NSRange r = [p rangeOfString:@"/" options:NSBackwardsSearch];
    return (r.location == NSNotFound) ? p : [p substringFromIndex:r.location + 1];
}

static BOOL isVideoPath(NSString *path)
{
    static NSSet *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[
            @"mp4", @"m4v", @"mov", @"mkv", @"avi", @"webm",
            @"mpg", @"mpeg", @"wmv", @"flv", @"ts", @"mts", @"m2ts"
        ]];
    });
    return [exts containsObject:path.pathExtension.lowercaseString];
}

static void shufflePaths(NSMutableArray *items)
{
    for (NSUInteger i = items.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [items exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
}

static void seekBy(int index, long deltaMs)
{
    if (index < 0 || index >= NCELLS) return;
    libvlc_media_player_t *p = g_cells[index].player;
    if (!p) return;
    int64_t t = libvlc_media_player_get_time(p);          /* milliseconds */
    if (t < 0) t = 0;
    int64_t nt = t + (int64_t)deltaMs;
    if (nt < 0) nt = 0;
    libvlc_media_player_set_time(p, nt);
    NSLog(@"[sixplayer] cell %d (%c): seek %+ld s", index + 1, g_cells[index].letter,
          (long)(deltaMs / 1000));
}

static void toggleMuteAt(int index)
{
    if (index < 0 || index >= NCELLS) return;
    libvlc_media_player_t *p = g_cells[index].player;
    if (!p) return;
    if (libvlc_audio_get_mute(p) != 0) {                  /* muted -> turn audio on */
        libvlc_audio_set_mute(p, 0);
        libvlc_audio_set_volume(p, 100);
        NSLog(@"[sixplayer] cell %d (%c) mute -> UNMUTED", index + 1, g_cells[index].letter);
    } else {
        libvlc_audio_set_mute(p, 1);
        NSLog(@"[sixplayer] cell %d (%c) mute -> MUTED", index + 1, g_cells[index].letter);
    }
}

/* ---------------- diagnostics + render check ---------------------------- */
static int  g_exitcode    = 0;      /* nonzero => a self-test check failed */
static int  g_renderfail  = 0;      /* count of black/blank cells */

static const char *stateName(int s)
{
    switch (s) {
      case 1: return "Opening";    case 2: return "Buffering";
      case 3: return "Playing";    case 4: return "Paused";
      case 5: return "Stopped";    case 6: return "Ended";
      case 7: return "Error";      default: return "?";
      }
}

/* Per-cell decode/advance snapshot. Works even headless because it reads the
 * libVLC C API, not the screen -- the answer to "are all 6 decoding?". */
static void diagCells(const char *phase)
{
    NSLog(@"[sixplayer] DIAG(%s) per-cell state:", phase);
    for (int i = 0; i < NCELLS; i++) {
        libvlc_media_player_t *p = g_cells[i].player;
        if (!p) { NSLog(@"[sixplayer]   cell %d (%c): NO PLAYER", i + 1, g_cells[i].letter);
                  continue; }
        int   st       = libvlc_media_player_get_state(p);
        int64_t t      = libvlc_media_player_get_time(p);    /* milliseconds */
        int   playing  = libvlc_media_player_is_playing(p);
        int   muted    = libvlc_audio_get_mute(p);
        int   ok = (st == 3);                                /* 3 == Playing */
        NSLog(@"[sixplayer]   cell %d (%c): state=%s t=%lldms playing=%d mute=%d%s",
              i + 1, g_cells[i].letter, stateName(st),
               (long long)t, playing, muted, ok ? "" : "    <- NOT PLAYING");
      }
}

/* Sample one cell's inner region of a snapshot -> luminance max/min (0..255) */
static void cellLums(CGImageRef img, size_t x0, size_t y0, size_t x1, size_t y1,
                     long *outMax, long *outMin)
{
    size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    size_t bpr = W * 4, bytes = bpr * H;
    uint8_t *buf = calloc(1, bytes);
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img);
    long mx = 0, mn = 255, n = 0;
    for (size_t y = y0 + 1; y < y1 - 1; y += 8)
        for (size_t x = x0 + 1; x < x1 - 1; x += 8) {
            uint8_t B = buf[(y * W + x) * 4 + 0];
            uint8_t G = buf[(y * W + x) * 4 + 1];
            uint8_t R = buf[(y * W + x) * 4 + 2];
            long l = (R + G + B) / 3;                        /* approx luminance */
            n++;
            if (l > mx)  mx = l;
            if (l < mn)  mn = l;
          }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(buf);
    if (!n) { *outMax = 0; *outMin = 255; return; }
    *outMax = mx; *outMin = mn;
}

/* Snapshot the full screen via Apple's 'screencapture' and prove none of the 6
 * cells is (near-)blank. A second capture ~0.6s later also detects motion, so a
 * momentarily-dark-but-playing cell still passes. 'screencapture' is Apple-signed
 * and handles Screen-Recording permission for us; if it returns nothing we FAIL
 * loudly (g_exitcode=4) instead of silently passing. */
static void renderCheckCells(void)
{
    g_renderfail = 0;
    const char *path1 = "/tmp/sixplayer_render.png";
    const char *path2 = "/tmp/sixplayer_render_second.png";
    char c1[300], c2[300];
    snprintf(c1, sizeof c1, "/usr/sbin/screencapture -x -o %s", path1);
    snprintf(c2, sizeof c2, "/usr/sbin/screencapture -x -o %s", path2);
    int rc1 = system(c1);
    NSLog(@"[sixplayer] RENDERCHECK: screencapture #1 rc=%d", rc1);
    NSLog(@"[sixplayer] RENDERCHECK screenshot: %s", path1);

    CGImageSourceRef src1 = CGImageSourceCreateWithURL(
          (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:path1]], NULL);
    CGImageRef img1 = src1 ? CGImageSourceCreateImageAtIndex(src1, 0, NULL) : nil;
    if (src1) CFRelease(src1);
    if (!img1) {
        NSLog(@"[sixplayer] RENDERCHECK FAIL: no usable screen capture -- on current macOS "
                "this means the launching terminal lacks 'Screen Recording' permission "
                "(System Settings > Privacy & Security > Screen Recording) or no GUI session, "
                "so the 6 cells cannot be visually verified.");
        g_renderfail = NCELLS;
        if (g_exitcode < 4) g_exitcode = 4;
        return;
      }

    size_t W = CGImageGetWidth(img1), H = CGImageGetHeight(img1);
    CGFloat cw = (CGFloat)W / COLS, ch = (CGFloat)H / ROWS;
    NSLog(@"[sixplayer] RENDERCHECK snapshot %zux%zu (cell %.0fx%.0f)", W, H, cw, ch);

    usleep(600000);                       /* gap so frame 2 differs (motion) */
    int rc2 = system(c2);
    (void)rc2;
    CGImageSourceRef src2 = CGImageSourceCreateWithURL(
          (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:path2]], NULL);
    CGImageRef img2 = src2 ? CGImageSourceCreateImageAtIndex(src2, 0, NULL) : nil;
    if (src2) CFRelease(src2);

    for (int i = 0; i < NCELLS; i++) {
        int col = i % COLS, row = i / COLS;
          /* Cocoa origin = bottom-left; capture origin = top-left, so the display
           * row counted from the top is (ROWS-1-row). */
        size_t x0 = (size_t)((CGFloat)col       * cw);
        size_t y0 = (size_t)((CGFloat)row       * ch);
        size_t x1 = (size_t)((CGFloat)(col + 1) * cw);
        size_t y1 = (size_t)((CGFloat)(row + 1) * ch);

        long mx1 = 0, mn1 = 255, mx2 = 0, mn2 = 255;
        cellLums(img1, x0, y0, x1, y1, &mx1, &mn1);
        if (img2) cellLums(img2, x0, y0, x1, y1, &mx2, &mn2);

        long range1 = mx1 - mn1, range2 = mx2 - mn2;               /* variety */
        long dmax   = (mx2 > mx1) ? (mx2 - mx1) : (mx1 - mx2);     /* motion   */
        int active = (mx1 > 16 || range1 > 22 || mx2 > 16 || range2 > 22 || dmax > 10);

        NSLog(@"[sixplayer] cell %d (%c) RENDER: maxLum=%ld range=%ld f2max=%ld f2range=%ld move=%ld -> %s",
              i + 1, g_cells[i].letter, mx1, range1, mx2, range2, dmax,
              active ? "PASS" : "FAIL (black/blank)");
        if (!active) g_renderfail++;
      }

    if (img2) CGImageRelease(img2);
    CGImageRelease(img1);
    remove(path2);
    NSLog(@"[sixplayer] RENDERCHECK result: %d/%d cells rendering -> %s",
          NCELLS - g_renderfail, NCELLS,
          g_renderfail == 0 ? "PASS (all 6 non-black)" : "FAIL (blank cells)");
    if (g_renderfail > 0 && g_exitcode < 3) g_exitcode = 3;
}

static void setCheatVisible(BOOL visible);

static int indexForKey(unichar lc)
{
    NSUInteger idx = [g_letters indexOfObject:[NSString stringWithCharacters:&lc length:1]];
    if (idx == NSNotFound || idx >= NCELLS) return -1;
    return (int)idx;
}

static void handleKey(unichar lc, BOOL shift, BOOL option)
{
    if (lc == 27) {                                       /* Esc: toggle cheat sheet */
        setCheatVisible(!g_cheat);
        return;
    }
    if (option) {                                          /* Option + letter -> mute toggle */
        int idx = indexForKey(lc);
        if (idx >= 0) toggleMuteAt(idx);
        return;
    }
    if (shift) {                                           /* Shift + letter -> backward */
        int idx = indexForKey(lc);
        if (idx >= 0) seekBy(idx, -SKIP_MS);
        return;
    }
    int idx = indexForKey(lc);
    if (idx >= 0) seekBy(idx, +SKIP_MS);                  /* plain letter -> forward */

    if (lc == 'q') [NSApp terminate:nil];                  /* q / Cmd-Q: quit */
}

/* ------------------------------- path setup -------------------------------- */

static void resolvePaths(NSMutableArray *paths, int argc, char **argv)
{
    /* 1) positional CLI args. */
    int added = 0;
    for (int n = 1; n < argc && added < NCELLS; n++) {
        const char *a = argv[n];
        if (!a || !a[0]) continue;
         [paths addObject:normPath([NSString stringWithUTF8String:a])];
        added++;
    }
    if (added > 0) return;

    /* 2) default: choose 6 random video files directly from ~/Downloads. */
    NSString *downloads = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:downloads error:NULL];
    NSMutableArray *videos = [NSMutableArray array];
    for (NSString *file in entries) {
        NSString *full = [downloads stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        if (isVideoPath(full)) [videos addObject:full];
    }
    shufflePaths(videos);
    for (NSString *video in videos) {
        [paths addObject:video];
        if (paths.count >= NCELLS) break;
    }
}

/* --------------------------------- views ----------------------------------- */

@implementation CellView
- (void)drawRect:(NSRect)r
{
    [[NSColor colorWithCalibratedWhite:0.03f alpha:1.0f] set];
    NSRectFill(r);
}
@end

@implementation KeyWindow
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)keyDown:(NSEvent *)e
{
    NSUInteger mf = [e modifierFlags];
    BOOL shift  = (mf & NSEventModifierFlagShift)  != 0;
    BOOL option = (mf & NSEventModifierFlagOption) != 0;
    /* charactersIgnoringModifiers gives the raw key; 'a' may come through uppercase
       when Shift is held, so match on the lower-cased base letter. */
    NSString *ks = [e charactersIgnoringModifiers];
    if (ks.length == 0) return;
    unichar c = [ks characterAtIndex:0];
    unichar lc = (c >= 'A' && c <= 'Z') ? (unichar)(c + 32) : c;
    handleKey(lc, shift, option);
}
@end

@implementation OverlayView
{
    __weak OverlayView *_self;
}
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)r
{
    if (!g_cheat) return;                                 /* hidden = pure video */
    /* panel */
    [[NSColor colorWithCalibratedWhite:0 alpha:0.45f] set];
    NSRectFill([self bounds]);

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentLeft;
    ps.lineBreakMode = NSLineBreakByClipping;

    NSArray *rows = @[
      @"sixplayer  --  6 videos, fullscreen 3x2. Each video = one home-row letter.",
      @"------------------------------------------------------------",
      [NSString stringWithFormat:@"  a s d f g h     forward  +%lds        (Shift+letter = backward -%lds)",
          (long)(SKIP_MS / 1000), (long)(SKIP_MS / 1000)],
      @"  Option+letter  toggle that video's sound     (all start MUTED)",
      @"  q / Cmd-Q    quit            Esc   show/hide this sheet",
      @"------------------------------------------------------------",
      @"   cell   key   file                         status"
    ];
    NSDictionary *head = @{ NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0f alpha:0.95f],
                            NSParagraphStyleAttributeName: ps };
    CGFloat yy = 0.86f * [self bounds].size.height;
    for (NSString *line in rows) {
        [line drawAtPoint:NSMakePoint(40, yy) withAttributes:head];
        yy -= 22;
    }
    NSDictionary *cellAttr = @{ NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.98f alpha:0.95f],
                                NSParagraphStyleAttributeName: ps };
    for (int i = 0; i < NCELLS; i++) {
        NSString *base = g_cells[i].path ? baseName(g_cells[i].path) : @"(no file)";
        if (base.length > 24) base = [base substringToIndex:24];
        const char *st = "not started";
        if (g_cells[i].player) st = libvlc_media_player_is_playing(g_cells[i].player) ? "playing" : "paused";
        int m = g_cells[i].player ? libvlc_audio_get_mute(g_cells[i].player) : 1;
        NSString *line = [NSString stringWithFormat:
            @"   %d    %c      %-24@   [%s]  %s",
            i + 1, g_cells[i].letter,
            base, st,
            m ? "MUTED" : "SOUND ON"];
        [line drawAtPoint:NSMakePoint(60, yy) withAttributes:cellAttr];
        yy -= 20;
    }
}
@end

/* --------------------------------- build ----------------------------------- */

static void setCheatVisible(BOOL visible)
{
    g_cheat = visible;
    if (g_overlay) {
        g_overlay.hidden = !visible;
        [g_overlay setNeedsDisplay:YES];
    }
    if (g_overlayWindow) {
        if (visible) {
            [g_overlayWindow makeKeyAndOrderFront:nil];
        } else {
            [g_overlayWindow orderOut:nil];
            [g_window makeKeyWindow];
        }
    }
}

static void buildUI(NSArray *paths)
{
    g_letters = [NSArray arrayWithObjects: @"a", @"s", @"d", @"f", @"g", @"h", nil];
    NSLog(@"[sixplayer] libVLC %s, %d cells, skip=%ld s",
          libvlc_get_version(), NCELLS, (long)(SKIP_MS / 1000));

    NSRect frame = [[NSScreen mainScreen] frame];
    CGFloat cw = frame.size.width  / COLS;
    CGFloat ch = frame.size.height / ROWS;

    for (int i = 0; i < NCELLS; i++) {
        g_cells[i].index = i;
        NSString *letter = g_letters[i];
        g_cells[i].letter = [letter characterAtIndex:0];
        g_cells[i].player = NULL;
        g_cells[i].media  = NULL;
        g_cells[i].window = nil;

        int col = i % COLS, row = i / COLS;
        CGFloat x = frame.origin.x + (CGFloat)col * cw;
        CGFloat y = frame.origin.y + (CGFloat)(ROWS - 1 - row) * ch;
        NSRect cellFrame = NSMakeRect(x, y, cw, ch);

        KeyWindow *w = [[KeyWindow alloc]
            initWithContentRect:cellFrame
                      styleMask:NSWindowStyleMaskBorderless
                       backing:NSBackingStoreBuffered
                         defer:NO];
        w.level = NSMainMenuWindowLevel + 4;
        w.backgroundColor = [NSColor blackColor];
        w.opaque = YES;
        w.releasedWhenClosed = NO;
        [w setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorIgnoresCycle)];

        CellView *v = [CellView new];
        v.wantsLayer = NO;
        v.frame = NSMakeRect(0, 0, cw, ch);
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [w setContentView:v];
        [w orderFront:nil];

        g_cells[i].window = w;
        g_cells[i].view = v;
        if (i == 0) g_window = w;
    }

    g_overlay = [OverlayView new];
    g_overlay.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    g_overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_overlayWindow = [[KeyWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                   backing:NSBackingStoreBuffered
                     defer:NO];
    g_overlayWindow.level = NSMainMenuWindowLevel + 5;
    g_overlayWindow.backgroundColor = [NSColor clearColor];
    g_overlayWindow.opaque = NO;
    g_overlayWindow.hasShadow = NO;
    g_overlayWindow.releasedWhenClosed = NO;
    [g_overlayWindow setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                            NSWindowCollectionBehaviorIgnoresCycle)];
    [g_overlayWindow setContentView:g_overlay];

    @try {
        if (g_cheat) {
            [g_overlayWindow makeKeyAndOrderFront:nil];
        } else {
            [g_window makeKeyAndOrderFront:nil];
        }
        [NSApp activateIgnoringOtherApps:YES];
    } @catch (NSException *e) { NSLog(@"[sixplayer] activate warning: %@", e); }

    const char *c = NULL;
    for (int i = 0; i < NCELLS; i++) {
        if (i >= (NSInteger)paths.count) { NSLog(@"[sixplayer] cell %d: no path", i + 1); continue; }
        NSString *p = paths[i];
        g_cells[i].path = [p copy];
        c = [p fileSystemRepresentation];
        libvlc_media_t *m = libvlc_media_new_path(g_inst, c);
        if (!m) { NSLog(@"[sixplayer] cell %d: media FAILED (%@)", i + 1, p); continue; }
        libvlc_media_player_t *mp = libvlc_media_player_new_from_media(m);
        if (!mp) { NSLog(@"[sixplayer] cell %d: player FAILED", i + 1); libvlc_media_release(m); continue; }
        g_cells[i].media  = m;
        g_cells[i].player = mp;
        libvlc_media_player_set_nsobject(mp, (__bridge const void *)g_cells[i].view);
        libvlc_audio_set_mute(mp, 1);                          /* ---- start MUTED ---- */
        int ret = libvlc_media_player_play(mp);
        NSLog(@"[sixplayer] cell %d (%c): playing %@ -- MUTED (ret=%d)",
              i + 1, g_cells[i].letter, baseName(p), ret);
    }

    g_tick = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [g_overlay setNeedsDisplay:YES];
     }];
    [[NSRunLoop mainRunLoop] addTimer:g_tick forMode:NSDefaultRunLoopMode];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            setCheatVisible(NO);
         });
}

/* ------------------------- delegate + self-test ---------------------------- */

static int countPlayingPlayers(void)
{
    int playing = 0;
    for (int i = 0; i < NCELLS; i++) {
        libvlc_media_player_t *p = g_cells[i].player;
        if (p && libvlc_media_player_is_playing(p)) playing++;
    }
    return playing;
}

static void cleanupPlayback(void)
{
    [g_tick invalidate];
    g_tick = nil;
    for (int i = 0; i < NCELLS; i++) {
        if (g_cells[i].player) {
            libvlc_media_player_release(g_cells[i].player);
            g_cells[i].player = NULL;
        }
        if (g_cells[i].media) {
            libvlc_media_release(g_cells[i].media);
            g_cells[i].media = NULL;
        }
    }
    if (g_inst) {
        libvlc_release(g_inst);
        g_inst = NULL;
    }
}

static void scheduleSelfTestIfRequested(void)
{
    const char *stw = getenv("SIXPLAY_SELFTEST");
    if (!stw || !stw[0]) return;

    if (strstr(stw, "render") != NULL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                setCheatVisible(NO);
                [g_window displayIfNeeded];
                diagCells("render-before-check");
                if (countPlayingPlayers() < NCELLS && g_exitcode < 2) g_exitcode = 2;
                renderCheckCells();
                cleanupPlayback();
                exit(g_exitcode);
            });
        return;
    }

    int seconds = (strcmp(stw, "auto") == 0) ? 5 : atoi(stw);
    if (seconds <= 0) seconds = 3;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            diagCells("selftest");
            if (countPlayingPlayers() < NCELLS && g_exitcode < 2) g_exitcode = 2;
            cleanupPlayback();
            exit(g_exitcode);
        });
}

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note;
    NSLog(@"[sixplayer] start: skip=%ld s, grid=%dx%d, %d cells",
          (long)(SKIP_MS / 1000), COLS, ROWS, NCELLS);

    g_inst = libvlc_new(0, NULL);
    if (!g_inst) {
        fprintf(stderr, "libvlc_new FAILED\n");
        g_exitcode = 1;
        [NSApp terminate:nil];
        return;
    }

    NSMutableArray *paths = [NSMutableArray array];
    resolvePaths(paths, g_argc, g_argv);
    if (paths.count < NCELLS) {
        NSLog(@"[sixplayer] WARNING: only %lu video path(s) resolved; need %d for a full grid",
              (unsigned long)paths.count, NCELLS);
        if (g_exitcode < 2) g_exitcode = 2;
    }
    for (NSString *p in paths) NSLog(@"[sixplayer] using: %@", p);

    buildUI(paths);
    scheduleSelfTestIfRequested();
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    cleanupPlayback();
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        g_argc = argc;
        g_argv = argv;

        const char *skip = getenv("SKIP_SECONDS");
        if (skip && skip[0]) {
            char *end = NULL;
            long seconds = strtol(skip, &end, 10);
            if (end != skip && seconds > 0) SKIP_MS = seconds * 1000;
        }

        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return g_exitcode;
}
