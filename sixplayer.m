//
//  sixplayer -- 6 VLC videos, fullscreen 3x2 grid, controlled per-key, all start MUTED.
//
//  Drives the libVLC that ships inside /Applications/VLC.app (no separate install).
//  Each cell gets its own libvlc_media_player_t embedded into an on-screen NSView via
//  libvlc_media_player_set_nsobject() (VLC's documented macOS embed), then we seek and
//  mute it directly with the libVLC C API.
//
//  Key map (each video owns one letter):
//       a s d z x c      = video 1..6 -> forward by SKIP seconds (default 60)
//       Shift + letter   = that video -> backward by SKIP seconds
//       Control + letter = use the long skip (default 5 minutes)
//       Option + letter  = that video -> toggle mute (videos start muted)
//       q / Cmd-Q        = quit          ? / Esc = show/hide the cheat sheet
//
//  Build+run via run.sh or package as a self-contained app. The only libVLC
//  symbols used are declared here via extern, so the build is immune to
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
extern int64_t libvlc_media_player_get_length(libvlc_media_player_t *);
extern const char *libvlc_get_version(void);

/* ---------------------------------- state ---------------------------------- */
#define NCELLS 6
#define COLS   3
#define ROWS   2

@interface CellView     : NSView @end   /* per-cell dark background; VLC embeds into its layer */
@interface OverlayView   : NSView @end  /* full-screen top view; draws the cheat sheet + progress bars */
@interface KeyWindow  : NSWindow @end /* borderless, can become key, captures the keyboard */
@interface AppDelegate : NSObject <NSApplicationDelegate> @end

/* --- Drag-and-drop launcher (issue #4). The selection model below is
    * intentionally free of an NSWindow and of libVLC, so its behavior can be
    * tested without a window or a full six-cell playback. --- */
@class VideoWallSelection;
@class DropView;
@interface SelectionWindowController : NSObject
- (void)show;
@end

struct Cell {
    int index;
    int letter;
    NSString *path;
    libvlc_media_t        *media;
    libvlc_media_player_t *player;
    CellView              *view;
    NSWindow              *window;
    CFAbsoluteTime         progressShownAt;   /* CFAbsoluteTime when overlay was last triggered */
};

static struct Cell g_cells[NCELLS];
static NSArray *g_letters = nil;
static NSWindow       *g_window  = nil;
static NSWindow       *g_overlayWindow = nil;
static OverlayView    *g_overlay = nil;
static libvlc_instance_t *g_inst = nil;
static NSTimer        *g_tick    = nil;
static BOOL            g_cheat   = YES;
static long            SKIP_MS = 60000;
static long            CONTROL_SKIP_MS = 300000;
static CFAbsoluteTime  PROGRESS_VISIBLE_SECS = 3.0;
static int             g_argc = 0;
static char          **g_argv = NULL;
static SelectionWindowController *g_selector = nil;     /* the launcher window (issue #4) */

/* Forward declarations so the launch router + selection UI can reach the playback
    * startup, the minimal menu, and the selection self-test before they are defined. */
static void buildUI(NSArray *paths);
static void startPlaybackWithPaths(NSArray *paths);
static void installMinimalMenu(void);
static BOOL ensureLibVLCInstance(void);
static void scheduleSelfTestIfRequested(void);
static int  runSelectionTests(void);

/* Cell 1..6 letters, left-to-right then top-to-bottom. Shared by the cheat-sheet
    * grid and the selection window so a dropped file maps to a clear, documented slot. */
static const char *kCellLetters[NCELLS] = { "a", "s", "d", "z", "x", "c" };

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

/* Format a millisecond duration as "M:SS" (hours prefixes "H:MM:SS" when present). */
static NSString *timeText(int64_t ms)
{
    if (ms <= 0) return @"0:00";
    long long totalSec = ms / 1000;
    long long h = totalSec / 3600;
    long long m = (totalSec % 3600) / 60;
    long long s = totalSec % 60;
    if (h > 0) return [NSString stringWithFormat:@"%lld:%02lld:%02lld", h, m, s];
    return [NSString stringWithFormat:@"%lld:%02lld", m, s];
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

static NSString *bundledVLCPath(NSString *child)
{
    NSString *resourceRoot = NSBundle.mainBundle.resourcePath;
    if (resourceRoot.length == 0) return nil;

    NSString *candidate = [[resourceRoot stringByAppendingPathComponent:@"vlc"]
                                stringByAppendingPathComponent:child];
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDir] && isDir)
        return candidate;
    return nil;
}

static void setEnvPathIfUnset(const char *name, NSString *path, const char *label)
{
    const char *current = getenv(name);
    if (current && current[0]) return;
    if (path.length == 0) return;

    if (setenv(name, path.fileSystemRepresentation, 0) == 0) {
        NSLog(@"[sixplayer] %s defaulted to %s", name, label);
    } else {
        NSLog(@"[sixplayer] WARNING: failed to set %s to %s", name, label);
    }
}

static void configureVLCRuntimePaths(void)
{
    NSString *plugins = bundledVLCPath(@"plugins");
    if (plugins) {
        setEnvPathIfUnset("VLC_PLUGIN_PATH", plugins, "bundled VLC plugins");
    } else {
        setEnvPathIfUnset("VLC_PLUGIN_PATH", @"/Applications/VLC.app/Contents/MacOS/plugins",
                            "/Applications/VLC.app plugins");
    }

    NSString *share = bundledVLCPath(@"share");
    if (share) setEnvPathIfUnset("VLC_DATA_PATH", share, "bundled VLC data");
}

static BOOL ensureLibVLCInstance(void)
{
    if (g_inst) return YES;

    configureVLCRuntimePaths();
    g_inst = libvlc_new(0, NULL);
    if (!g_inst) {
        fprintf(stderr, "libvlc_new FAILED\n");
        return NO;
    }
    return YES;
}

/* ============================================================================ */
/*  issue #4 -- drag-and-drop launcher                                           */
/* ============================================================================ */

/* Return YES when 'p' is an existing directory, so folder drops are ignored even
    * when their name ends in a video extension. A path that does not exist is not a
    * folder (in a test a candidate video need not exist on disk yet). */
static BOOL pathIsDirectory(NSString *p)
{
    BOOL isDir = NO;
    if (p.length == 0) return NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir])
        return isDir;
    return NO;
}

/* The selection model -- the testable seam. It reuses the SAME video-extension
    * rule as the command line (isVideoPath / normPath) so the GUI and CLI cannot
    * drift. It ignores folders and duplicates, caps the selection at NCELLS, keeps
    * an ordered path list to hand straight to playback, and has NO NSWindow and NO
    * libVLC dependency -- so launcher behavior is verifiable without full playback. */
@interface VideoWallSelection : NSObject
@property (nonatomic, copy, nullable) void (^onPlay)(NSArray<NSString *> *paths);
- (instancetype)init;
- (void)addPaths:(NSArray<NSString *> *)candidate;
- (void)removeAtCell:(NSInteger)index;
- (void)clear;
- (void)play;
- (NSInteger)count;
- (BOOL)isComplete;
- (NSArray<NSString *> *)selectedPaths;
- (NSString *)statusMessage;
- (NSInteger)lastAcceptedCount;
- (NSInteger)lastRejectedCount;
@end

@interface VideoWallSelection ()
- (void)refreshStatus;
@end

@implementation VideoWallSelection
{
    NSMutableArray<NSString *> *_paths;          /* accepted, in drop order */
    NSMutableSet<NSString *>     *_seen;            /* dedup keys == accepted paths */
    NSMutableSet<NSString *>     *_reasons;         /* distinct skip reasons, last batch */
    NSString                    *_status;           /* user-facing status line */
    NSInteger                    _lastAccepted;
    NSInteger                    _lastRejected;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
            _paths        = [NSMutableArray array];
            _seen         = [NSMutableSet set];
            _reasons      = [NSMutableSet set];
            _lastAccepted = 0;
            _lastRejected = 0;
            [self refreshStatus];
        }
    return self;
}

- (NSInteger)count              { return (NSInteger)_paths.count; }
- (BOOL)isComplete              { return _paths.count == (NSUInteger)NCELLS; }
- (NSArray<NSString *> *)selectedPaths { return [_paths copy]; }
- (NSString *)statusMessage       { return _status; }
- (NSInteger)lastAcceptedCount   { return _lastAccepted; }
- (NSInteger)lastRejectedCount   { return _lastRejected; }

/* Add a batch of dropped paths. Each candidate is normalized, then screened in
    * priority order: folder -> not-a-video -> duplicate -> over-cap. Everything
    * that passes is appended (in order); the batch's accept/reject tallies + the
    * skip reasons feed the status line. */
- (void)addPaths:(NSArray<NSString *> *)candidate
{
    NSInteger accepted = 0, rejected = 0;
        [_reasons removeAllObjects];

    for (id raw in candidate) {
            if (![raw isKindOfClass:[NSString class]]) { rejected++; continue; }
        NSString *p = normPath((NSString *)raw);
        if (p.length == 0) continue;

            /* folder first: a directory's name may end in .mp4 yet isn't a video */
        if (pathIsDirectory(p))            { rejected++; [_reasons addObject:@"folder"];         continue; }
        if (!isVideoPath(p))               { rejected++; [_reasons addObject:@"not a video"];    continue; }
        else if ([_seen containsObject:p]) { rejected++; [_reasons addObject:@"duplicate"];      continue; }
        else if (_paths.count >= (NSUInteger)NCELLS) { rejected++; [_reasons addObject:@"selection full"]; continue; }

            [_paths addObject:p];
            [_seen  addObject:p];
        accepted++;
        }

        _lastAccepted = accepted;
        _lastRejected = rejected;
        [self refreshStatus];
}

/* Remove one cell (its selected table row). The remaining videos shift up, which
    * drops the count below six and therefore re-disables Play. */
- (void)removeAtCell:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)_paths.count) return;
    NSString *p = _paths[index];
        [_paths removeObjectAtIndex:index];
        [_seen  removeObject:p];
        _lastAccepted = 0;
        _lastRejected = 0;
        [_reasons removeAllObjects];
        [self refreshStatus];
}

- (void)clear
{
        [_paths  removeAllObjects];
        [_seen   removeAllObjects];
        [_reasons removeAllObjects];
        _lastAccepted = 0;
        _lastRejected = 0;
        [self refreshStatus];
}

/* Fire the handoff only when the selection is exactly six. */
- (void)play
{
    if (_paths.count != (NSUInteger)NCELLS) return;
    if (self.onPlay) self.onPlay([_paths copy]);
}

/* One concise status line: when the most recent drop skipped anything it leads
    * with a short "Skipped N file(s): ..." note, then the current selection state. */
- (void)refreshStatus
{
    NSString *base;
    switch ((NSInteger)_paths.count) {
        case 0:
        base = [NSString stringWithFormat:@"Drag video files into the window, then press Play (need %d).",
                NCELLS];
        break;
        default:
        if (_paths.count == (NSUInteger)NCELLS) {
            base = [NSString stringWithFormat:@"%d of %d videos ready -- press Play.", NCELLS, NCELLS];
            } else {
            base = [NSString stringWithFormat:@"%ld of %ld videos selected -- add %ld more.",
                        (long)_paths.count, (long)NCELLS, (long)((NSUInteger)NCELLS - _paths.count)];
            }
        break;
        }
    if (_lastRejected > 0) {
        NSArray *rs = [_reasons.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        base = [NSString stringWithFormat:@"Skipped %ld file(s): %@. %@",
                    (long)_lastRejected, [rs componentsJoinedByString:@", "], base];
        }
        _status = [base copy];
}
@end

/* ---- Launch routing: keep "GUI app launch" distinct from "CLI launch" ---- */
typedef NS_ENUM(NSInteger, LaunchKind) {
    LaunchSelectWindow,     /* interactive + no paths  -> show the drag-and-drop picker */
    LaunchDirectPlayback,   /* positional video paths  -> skip the picker, play now      */
    LaunchSelfTest,         /* SIXPLAY_SELFTEST set   -> build + auto-verify, no picker  */
};

/* Pure decision, so it can be tested without an NSApplication: a self-test request
    * verifies; positional video paths play directly (bypassing the picker); an
    * ordinary launch shows the picker. */
static LaunchKind computeLaunchKind(int argc, char **argv, const char *selftestEnv)
{
    if (selftestEnv && selftestEnv[0]) return LaunchSelfTest;
    int positional = 0;
    for (int n = 1; n < argc; n++)
        if (argv[n] && argv[n][0] != '\0') positional++;
    return (positional > 0) ? LaunchDirectPlayback : LaunchSelectWindow;
}

static void showProgressOverlayForCell(int index)
{
    g_cells[index].progressShownAt = CFAbsoluteTimeGetCurrent();
    if (g_overlay) {
        g_overlay.hidden = NO;
        [g_overlay setNeedsDisplay:YES];
    }
    if (g_overlayWindow) {
        [g_overlayWindow orderFront:nil];
        if (!g_cheat && g_window) [g_window makeKeyWindow];
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
    showProgressOverlayForCell(index);
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

static BOOL isCheatToggleKey(unichar typed, unichar rawLc, BOOL shift)
{
    return typed == '?' || rawLc == 27 || (shift && rawLc == '/');
}

static void handleKey(unichar typed, unichar lc, BOOL shift, BOOL option, BOOL control)
{
    if (isCheatToggleKey(typed, lc, shift)) {
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
        if (idx >= 0) seekBy(idx, -(control ? CONTROL_SKIP_MS : SKIP_MS));
        return;
    }
    int idx = indexForKey(lc);
    if (idx >= 0) seekBy(idx, +(control ? CONTROL_SKIP_MS : SKIP_MS));

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
    BOOL shift   = (mf & NSEventModifierFlagShift)   != 0;
    BOOL option  = (mf & NSEventModifierFlagOption)  != 0;
    BOOL control = (mf & NSEventModifierFlagControl) != 0;
    /* charactersIgnoringModifiers gives the raw key; 'a' may come through uppercase
        when Shift is held, so match on the lower-cased base letter. */
    NSString *ks = [e charactersIgnoringModifiers];
    if (ks.length == 0) return;
    unichar c = [ks characterAtIndex:0];
    unichar lc = (c >= 'A' && c <= 'Z') ? (unichar)(c + 32) : c;
    NSString *chars = [e characters];
    unichar typed = chars.length > 0 ? [chars characterAtIndex:0] : 0;
    handleKey(typed, lc, shift, option, control);
}
@end

@implementation OverlayView
{
    __weak OverlayView *_self;
}
- (BOOL)isOpaque { return NO; }
- (void)drawProgressOverlays
{
    /* Per-cell seek progress bars, drawn on the full-screen overlay so they always
        sit above the VLC video (same mechanism as the cheat sheet). Each cell shows
        its own bar for PROGRESS_VISIBLE_SECS after a seek. */
    for (int i = 0; i < NCELLS; i++) {
        struct Cell *cell = &g_cells[i];
        if (!cell->player || !cell->window) continue;
        CFAbsoluteTime age = CFAbsoluteTimeGetCurrent() - cell->progressShownAt;
        if (age < 0 || age > PROGRESS_VISIBLE_SECS) continue;      /* stale -> skip */

        NSRect cellFrame = [self convertRect:[g_overlayWindow convertRectFromScreen:cell->window.frame]
                                    fromView:nil];
        if (NSWidth(cellFrame) <= 0 || NSHeight(cellFrame) <= 0) continue;

        int64_t cur   = libvlc_media_player_get_time(cell->player);
        int64_t total = libvlc_media_player_get_length(cell->player);
        if (cur < 0) cur = 0;
        double frac = 0.0;
        if (total > 0) frac = (double)cur / (double)total;
        if (frac > 1.0) frac = 1.0;

        CGFloat barH = 28.0f;
        NSRect band = NSMakeRect(NSMinX(cellFrame), NSMinY(cellFrame), NSWidth(cellFrame), barH);
        [[NSColor colorWithCalibratedWhite:0 alpha:0.55f] set];
        NSRectFill(band);

        NSRect track = NSMakeRect(NSMinX(cellFrame), NSMinY(cellFrame) + barH - 3.0f,
                                    NSWidth(cellFrame), 3.0f);
        [[NSColor colorWithCalibratedWhite:1 alpha:0.25f] set];
        NSRectFill(track);
        NSRect fill = NSMakeRect(NSMinX(track), NSMinY(track), NSWidth(track) * frac, 3.0f);
        [[NSColor systemBlueColor] set];
        NSRectFill(fill);

        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentRight;
        NSDictionary *attr = @{
            NSFontAttributeName            : [NSFont monospacedDigitSystemFontOfSize:13.0f
                                                        weight:NSFontWeightMedium],
            NSForegroundColorAttributeName : [NSColor whiteColor],
            NSParagraphStyleAttributeName  : ps
        };
        NSString *label = [NSString stringWithFormat:@"%@  /  %@",
                            timeText(cur), timeText(total)];
        [label drawInRect:NSMakeRect(NSMinX(cellFrame) + 8.0f,
                                    NSMinY(cellFrame) + (barH - 16.0f) / 2.0f,
                                    NSWidth(cellFrame) - 16.0f, 16.0f)
            withAttributes:attr];
    }
}
- (void)drawCheatSheet
{
    NSRect bounds = [self bounds];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.45f] set];
    NSRectFill(bounds);

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentLeft;
    ps.lineBreakMode = NSLineBreakByClipping;

    NSArray *rows = @[
        @"Video Wall Player  --  6 videos, fullscreen 3x2. Each video = one letter.",
        @"------------------------------------------------------------",
        [NSString stringWithFormat:@"  a s d z x c     forward  +%lds        (Shift = back, Control = %ldm)",
            (long)(SKIP_MS / 1000), (long)(CONTROL_SKIP_MS / 60000)],
        @"  Option+letter  toggle that video's sound     (all start MUTED)",
        @"  q / Cmd-Q    quit            ? / Esc   show/hide this sheet",
        @"------------------------------------------------------------",
        @"   cell   key   file                         status"
    ];
    NSDictionary *head = @{ NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0f alpha:0.95f],
                            NSParagraphStyleAttributeName: ps };

    CGFloat margin = bounds.size.width < 480.0f ? 16.0f : 40.0f;
    CGFloat headerLineHeight = 22.0f;
    CGFloat cellLineHeight = 20.0f;
    CGFloat contentWidth = MIN(704.0f, MAX(0.0f, bounds.size.width - (2.0f * margin)));
    CGFloat contentHeight = MIN((rows.count * headerLineHeight) + (NCELLS * cellLineHeight),
                                MAX(0.0f, bounds.size.height - (2.0f * margin)));
    NSRect textRect = NSMakeRect(NSMidX(bounds) - (contentWidth / 2.0f),
                                    NSMidY(bounds) - (contentHeight / 2.0f),
                                    contentWidth,
                                    contentHeight);
    CGFloat yy = NSMaxY(textRect) - headerLineHeight;
    for (NSString *line in rows) {
        [line drawInRect:NSMakeRect(NSMinX(textRect), yy, textRect.size.width, headerLineHeight)
            withAttributes:head];
        yy -= headerLineHeight;
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
        [line drawInRect:NSMakeRect(NSMinX(textRect) + 20.0f, yy,
                                    MAX(0.0f, textRect.size.width - 20.0f), cellLineHeight)
            withAttributes:cellAttr];
        yy -= cellLineHeight;
    }
}
- (void)drawRect:(NSRect)r
{
    (void)r;
    if (g_cheat) [self drawCheatSheet];
    [self drawProgressOverlays];          /* draw last so progress remains visible */
}
@end

/* --------------------------------- build ----------------------------------- */

static void setCheatVisible(BOOL visible)
{
    g_cheat = visible;
    if (g_overlay) {
        g_overlay.hidden = NO;                 /* keep overlay up: it draws progress bars too */
        [g_overlay setNeedsDisplay:YES];
    }
    if (g_overlayWindow) {
        /* The overlay window must stay up so per-cell progress bars render even while the
            cheat sheet is hidden. It is transparent, so the video still shows through. */
        [g_overlayWindow orderFront:nil];
        if (visible) {
            [g_overlayWindow makeKeyAndOrderFront:nil];
        } else {
            [g_window makeKeyWindow];
        }
    }
}

static void buildUI(NSArray *paths)
{
    NSMutableArray *letterBuf = [NSMutableArray array];
    for (int li = 0; li < NCELLS; li++)
        [letterBuf addObject:[NSString stringWithUTF8String:kCellLetters[li]]];
    g_letters = [letterBuf copy];
    NSLog(@"[sixplayer] libVLC %s, %d cells, skip=%ld s, control-skip=%ld s",
            libvlc_get_version(), NCELLS, (long)(SKIP_MS / 1000), (long)(CONTROL_SKIP_MS / 1000));

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

    g_tick = [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) {
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
    NSLog(@"[sixplayer] start: skip=%ld s, control-skip=%ld s, grid=%dx%d, %d cells",
            (long)(SKIP_MS / 1000), (long)(CONTROL_SKIP_MS / 1000), COLS, ROWS, NCELLS);

    installMinimalMenu();

    LaunchKind kind = computeLaunchKind(g_argc, g_argv, getenv("SIXPLAY_SELFTEST"));
    NSLog(@"[sixplayer] launch kind: %s",
            kind == LaunchSelfTest ? "self-test"
            : kind == LaunchDirectPlayback ? "direct-playback" : "selection-window");

    switch (kind) {
        case LaunchSelectWindow:
        default:
            /* Ordinary interactive launch: show the drag-and-drop picker and wait for
            * six selected videos before any playback starts. */
        NSLog(@"[sixplayer] showing drag-and-drop selection window");
        g_selector = [SelectionWindowController new];
            [g_selector show];
        break;

        case LaunchDirectPlayback:
        case LaunchSelfTest:
            /* CLI path args (or a self-test run) bypass the picker and drive playback
            * directly, preserving the documented workflow. */
        if (!ensureLibVLCInstance()) {
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
        startPlaybackWithPaths(paths);
        if (kind == LaunchSelfTest) scheduleSelfTestIfRequested();
        break;
        }
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    cleanupPlayback();
}
@end

/* =========================  launch + selection UI + tests  ================== */

/* Create the libvlc instance (once) and start the existing six-cell wall from a
    * chosen set of paths. This is the single handoff from "selected" to "playing". */
static void startPlaybackWithPaths(NSArray *paths)
{
    if (paths.count == 0) {
        NSLog(@"[sixplayer] refusing to start playback with no video paths");
        return;
            }
    if (!ensureLibVLCInstance()) {
        g_exitcode = 1;
                [NSApp terminate:nil];
        return;
            }
    NSLog(@"[sixplayer] starting 6-cell video wall from selection (%lu paths)",
            (unsigned long)paths.count);
    buildUI(paths);
}

/* A minimal app menu with a Cmd-Q "Quit", so the launcher always offers a way out
    * and the app menu exists even outside the full video wall. */
static void installMinimalMenu(void)
{
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
            [appItem setSubmenu:appMenu];
            [appMenu addItemWithTitle:@"Quit"
                            action:@selector(terminate:)
                    keyEquivalent:@"q"];
            [mainMenu addItem:appItem];
            [NSApp setMainMenu:mainMenu];
}

/* ---- the window's content view doubles as the Finder drop target ---- */
@interface DropView : NSView
@property (nonatomic, copy, nullable) void (^onFilesDropped)(NSArray<NSURL *> *fileURLs);
@end

@implementation DropView
{
    BOOL _highlight;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
            _highlight = NO;
            [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        }
    return self;
}

/* Accept only drags that carry at least one file URL (e.g. a Finder drop). */
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pb = [sender draggingPasteboard];
    BOOL hasFiles = [pb canReadObjectForClasses:@[[NSURL class]] options:nil];
    if (hasFiles) {
            _highlight = YES;
            [self setNeedsDisplay:YES];
        return NSDragOperationCopy;
        }
    return NSDragOperationNone;
}

- (void)draggingExited
{
        _highlight = NO;
        [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pb = [sender draggingPasteboard];
    return [pb canReadObjectForClasses:@[[NSURL class]] options:nil];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
    if (urls.count == 0) return NO;
    if (self.onFilesDropped) self.onFilesDropped(urls);
        _highlight = NO;
        [self setNeedsDisplay:YES];
    return YES;
}

- (void)drawRect:(NSRect)r
{
    NSRect b   = [self bounds];
        [[NSColor colorWithCalibratedWhite:0.08 alpha:1.0f] set];
    NSRectFill(b);

    NSColor *edge = _highlight
        ? [NSColor systemBlueColor]
        : [NSColor colorWithCalibratedWhite:0.35 alpha:1.0f];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(b, 1.5f, 1.5f)];
    border.lineWidth = 2.0f;
        [edge set];
        [border stroke];

    NSString *prompt = _highlight ? @"Drop videos here" : @"Drag video files in (up to 6)";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attr = @{
        NSFontAttributeName             : [NSFont systemFontOfSize:(_highlight ? 20.0f : 17.0f)
                                                weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : _highlight ? [NSColor whiteColor]
                                                        : [NSColor colorWithCalibratedWhite:0.85 alpha:1.0f],
        NSParagraphStyleAttributeName   : ps,
            };
            [prompt drawInRect:NSMakeRect(0.0f, NSMidY(b) - 16.0f, b.size.width, 32.0f)
                withAttributes:attr];
}
@end

/* ---- the selection window: instructions, a list, status, and Clear/Remove/Play ---- */
@interface SelectionWindowController () <NSWindowDelegate,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate>
- (void)handleDroppedURLs:(NSArray<NSURL *> *)urls;
- (void)beginPlaybackWithPaths:(NSArray<NSString *> *)paths;
- (void)refreshUI;
- (NSTextField *)makeLabel:(NSString *)s multi:(BOOL)multi
                        rect:(NSRect)r autoMask:(NSUInteger)mask;
- (void)onClear:(id)sender;
- (void)onRemove:(id)sender;
- (void)onPlay:(id)sender;
@end

@implementation SelectionWindowController
{
    NSWindow             *_window;
    DropView             *_dropView;        /* the window's content view is the drop target */
    NSTableView          *_list;
    NSTextField          *_countLabel;
    NSTextField          *_statusLabel;
    NSTextField          *_footerLabel;
    NSButton             *_clearButton;
    NSButton             *_removeButton;
    NSButton             *_playButton;
    VideoWallSelection  *_selection;
}

- (void)show
{
        _selection = [VideoWallSelection new];

            CGFloat W = 560.0f, H = 620.0f, m = 24.0f, bw = W - 2.0 * m;
    NSWindowStyleMask sm = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    _window = [[NSWindow alloc]
                    initWithContentRect:NSMakeRect(0, 0, W, H)
                        styleMask:sm
                            backing:NSBackingStoreBuffered
                            defer:NO];
        _window.title               = @"Video Wall Player -- pick 6 videos";
        _window.delegate            = self;
        _window.releasedWhenClosed = NO;
        [_window setMinSize:NSMakeSize(460.0f, 440.0f)];

        /* The whole content view is the drop target, so dropping outside the list still counts. */
    _dropView = [[DropView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    _dropView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        __weak SelectionWindowController *weakSelf = self;
    _dropView.onFilesDropped = ^(NSArray<NSURL *> *urls) {
        [weakSelf handleDroppedURLs:urls];
            };
            [_window setContentView:_dropView];

    NSTextField *inst =
            [self makeLabel:@"Drag one or more video files into the window, then press Play when six are ready.\n"
                    "Each selected video fills one cell: A B C on the top row, D E F on the bottom row."
                    multi:YES rect:NSMakeRect(m, H - 84.0f, bw, 78.0f)
                    autoMask:NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin];
    [inst setFont:[NSFont systemFontOfSize:13.0f weight:NSFontWeightRegular]];
            [_dropView addSubview:inst];

    _countLabel = [self makeLabel:@"0 of 6 videos selected" multi:NO
                rect:NSMakeRect(m, H - 108.0f, bw, 22.0f)
                autoMask:NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin];
    [_countLabel setFont:[NSFont systemFontOfSize:15.0f weight:NSFontWeightMedium]];
        [_dropView addSubview:_countLabel];

    _list = [[NSTableView alloc] init];
    _list.rowHeight = 24.0f;
    _list.usesAlternatingRowBackgroundColors = YES;
    _list.allowsMultipleSelection = NO;
    _list.dataSource = self;
    _list.delegate    = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"video"];
    col.title = @"Cell    /   video file";
    col.width = 300.0f;
    [_list addTableColumn:col];
        _list.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(m, 118.0f, bw, H - 108.0f - 118.0f - m)];
    scroll.documentView        = _list;
    scroll.hasVerticalScroller = YES;
    scroll.borderType          = NSBezelBorder;
    scroll.autoresizingMask    = NSViewWidthSizable | NSViewHeightSizable;
        [_dropView addSubview:scroll];

    _statusLabel = [self makeLabel:@"" multi:YES
                rect:NSMakeRect(m, 74.0f, bw, 38.0f)
                autoMask:NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin];
    [_statusLabel setFont:[NSFont systemFontOfSize:12.5f weight:NSFontWeightRegular]];
        [_dropView addSubview:_statusLabel];

    _footerLabel =
            [self makeLabel:@"Dropped folders, non-video files, and duplicates are skipped automatically."
                multi:NO rect:NSMakeRect(m, 52.0f, bw, 18.0f)
                autoMask:NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin];
    [_footerLabel setFont:[NSFont systemFontOfSize:11.0f weight:NSFontWeightRegular]];
    [_footerLabel setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0f]];
        [_dropView addSubview:_footerLabel];

    CGFloat by = 18.0f, bh = 32.0f;
    _clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClear:)];
    _clearButton.bezelStyle = NSBezelStyleRounded;
    _clearButton.frame = NSMakeRect(m, by, 90.0f, bh);
    _clearButton.autoresizingMask = NSViewMinYMargin;
        [_dropView addSubview:_clearButton];

    _removeButton = [NSButton buttonWithTitle:@"Remove selected" target:self action:@selector(onRemove:)];
    _removeButton.bezelStyle = NSBezelStyleRounded;
    _removeButton.frame = NSMakeRect(m + 102.0f, by, 150.0f, bh);
    _removeButton.autoresizingMask = NSViewMinYMargin;
        [_dropView addSubview:_removeButton];

    _playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(onPlay:)];
    _playButton.bezelStyle = NSBezelStyleRounded;
    _playButton.frame       = NSMakeRect(W - m - 120.0f, by, 120.0f, bh);
    _playButton.keyEquivalent = @"\r";            /* Return triggers Play when enabled */
    _playButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
        [_dropView addSubview:_playButton];

        _selection.onPlay = ^(NSArray<NSString *> *paths) {
            [weakSelf beginPlaybackWithPaths:paths];
            };

        [self refreshUI];
        [_window center];
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
}

- (NSTextField *)makeLabel:(NSString *)s
                        multi:(BOOL)multi
                        rect:(NSRect)r
                    autoMask:(NSUInteger)mask
{
    NSTextField *t = [NSTextField labelWithString:s];
            [t setBezeled:NO];
            [t setBordered:NO];
            [t setEditable:NO];
            [t setSelectable:NO];
            [t setDrawsBackground:NO];
    t.autoresizingMask = mask;
    t.frame            = r;
    if (multi) {
        t.usesSingleLineMode    = NO;
        t.maximumNumberOfLines   = 0;
        t.lineBreakMode         = NSLineBreakByWordWrapping;
        }
    return t;
}

- (void)handleDroppedURLs:(NSArray<NSURL *> *)urls
{
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.isFileURL) {
            NSString *p = u.path;
            if (p.length > 0) [paths addObject:p];
            }
        }
    if (paths.count == 0) return;                  /* folders / other payloads: no file URLs */
        [_selection addPaths:paths];
        [self refreshUI];
}

- (void)onClear:(id)sender
{
        [_selection clear];
        [self refreshUI];
}

- (void)onRemove:(id)sender
{
    NSInteger r = [_list selectedRow];
    if (r >= 0) [_selection removeAtCell:r];
        [self refreshUI];
}

- (void)onPlay:(id)sender
{
        [_selection play];                          /* fires onPlay when six are selected */
}

- (void)beginPlaybackWithPaths:(NSArray<NSString *> *)paths
{
        [_window orderOut:nil];
    startPlaybackWithPaths(paths);
}

- (void)refreshUI
{
        [_list reloadData];
    _countLabel.stringValue   = [NSString stringWithFormat:@"%ld of %d videos selected",
                                    (long)_selection.count, NCELLS];
    _statusLabel.stringValue  = _selection.statusMessage;
    _playButton.enabled       = _selection.isComplete;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)_selection.count;
}

- (id)tableView:(NSTableView *)tv
objectValueForTableColumn:(NSTableColumn *)column
                        row:(NSInteger)row
{
    NSArray *paths = _selection.selectedPaths;
    if (row < 0 || row >= (NSInteger)paths.count) return @"";
    NSString *name = baseName(paths[row]);
    if (name.length > 46) name = [name substringToIndex:46];
    char letter = (row < NCELLS) ? kCellLetters[row][0] : '-';
    return [NSString stringWithFormat:@"   %c    %s", (int)letter, [name UTF8String]];
}

- (BOOL)windowShouldClose:(NSWindow *)w
{
        [NSApp terminate:nil];
    return YES;
}
@end

/* ---- headless selection self-test (SIXPLAY_SELTEST) ----
    * Exercises the testable seam -- model, routing, and handoff -- WITHOUT a window
    * and WITHOUT libVLC/full playback, as the issue allows for GUI tests. The
    * two-second playback self-test in the CLI render mode is left untouched. */
static int g_test_fail  = 0;
static int g_test_total = 0;

static void tcheck(const char *name, BOOL ok)
{
            g_test_total++;
    fprintf(stderr, "   [sixplayer]   %-46s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) g_test_fail++;
}

@interface OverlayProbeView : OverlayView
- (NSArray<NSString *> *)events;
@end

@implementation OverlayProbeView
{
    NSMutableArray<NSString *> *_events;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)events
{
    return [_events copy];
}

- (void)drawCheatSheet
{
    [_events addObject:@"cheat"];
}

- (void)drawProgressOverlays
{
    [_events addObject:@"progress"];
}
@end

static int runSelectionTests(void)
{
            g_test_fail  = 0;
            g_test_total = 0;
    fprintf(stderr, "[sixplayer] selection self-test (model + handoff + routing)...\n");

        /* ---- launch routing ---- */
        {
        char *aWin[] = { "sixplayer" };
        char *aP1[]  = { "sixplayer", "/tmp/x.mp4" };
    tcheck("routing: no args -> selection window",
                        computeLaunchKind(1, aWin, NULL) == LaunchSelectWindow);
        tcheck("routing: CLI paths -> direct playback",
                        computeLaunchKind(2, aP1, NULL) == LaunchDirectPlayback);
        tcheck("routing: self-test env -> self-test",
                        computeLaunchKind(1, aWin, "3") == LaunchSelfTest);
        }

        /* ---- progress overlay must stay visible over the startup cheat sheet ---- */
        {
        BOOL savedCheat = g_cheat;
        g_cheat = YES;
        OverlayProbeView *probe = [[OverlayProbeView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [probe drawRect:probe.bounds];
        tcheck("progress overlay: drawn above cheat sheet",
                [[probe events] isEqualToArray:@[@"cheat", @"progress"]]);
        g_cheat = savedCheat;
        }

        /* ---- Finder/Xcode launch has no helper-script VLC_PLUGIN_PATH ---- */
        {
        const char *before = getenv("VLC_PLUGIN_PATH");
        char *saved = before ? strdup(before) : NULL;

        setenv("VLC_PLUGIN_PATH", "/tmp/custom-vlc-plugins", 1);
        configureVLCRuntimePaths();
        tcheck("vlc env: existing plugin path preserved",
                strcmp(getenv("VLC_PLUGIN_PATH"), "/tmp/custom-vlc-plugins") == 0);

        unsetenv("VLC_PLUGIN_PATH");
        configureVLCRuntimePaths();
        const char *defaulted = getenv("VLC_PLUGIN_PATH");
        tcheck("vlc env: desktop launch gets plugin path",
                defaulted && strcmp(defaulted, "/Applications/VLC.app/Contents/MacOS/plugins") == 0);

        if (saved) {
            setenv("VLC_PLUGIN_PATH", saved, 1);
            free(saved);
        } else {
            unsetenv("VLC_PLUGIN_PATH");
        }
        }

        /* ---- empty selection ---- */
    VideoWallSelection *sel = [VideoWallSelection new];
    tcheck("empty: count is 0", [sel count] == 0);
    tcheck("empty: Play disabled", !sel.isComplete);
    tcheck("empty: status is a hint", sel.statusMessage.length > 0);

        /* ---- one valid keeps Play disabled ---- */
        [sel addPaths:@[@"/tmp/clip1.mp4"]];
    tcheck("one: count == 1", [sel count] == 1);
    tcheck("one: Play still disabled", !sel.isComplete);
    tcheck("one: one accepted", sel.lastAcceptedCount == 1);

        /* ---- six valid enables Play + preserves drop order ---- */
    VideoWallSelection *s6 = [VideoWallSelection new];
    NSArray *six = @[@"/tmp/c1.mp4", @"/tmp/c2.m4v", @"/tmp/c3.mov",
                        @"/tmp/c4.mkv", @"/tmp/c5.avi", @"/tmp/c6.MP4"];
        [s6 addPaths:six];
    tcheck("six: count == 6", [s6 count] == 6);
    tcheck("six: Play enabled", s6.isComplete);
    tcheck("six: six accepted", s6.lastAcceptedCount == 6);
    tcheck("six: drop order preserved", [s6.selectedPaths isEqualToArray:six]);

        /* ---- non-video ignored (count + a visible message) ---- */
    VideoWallSelection *sBad = [VideoWallSelection new];
        [sBad addPaths:@[@"/tmp/a.txt", @"/tmp/b.log", @"/tmp/c.mp4"]];
    tcheck("non-video: only the video accepted", [sBad count] == 1);
    tcheck("non-video: two rejections recorded", sBad.lastRejectedCount == 2);
    tcheck("non-video: status has a message", sBad.statusMessage.length > 0);
    tcheck("non-video: message mentions a skip",
                [sBad.statusMessage rangeOfString:@"skip"
                                        options:NSCaseInsensitiveSearch].location != NSNotFound);

        /* ---- folders ignored even when the name ends in a video extension ---- */
    VideoWallSelection *sFolder = [VideoWallSelection new];
        {
        NSString *tmpdir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"sixplayer_sel_%@", [[NSUUID UUID] UUIDString]]];
        BOOL made = [NSFileManager.defaultManager
                        createDirectoryAtPath:tmpdir withIntermediateDirectories:YES
                                    attributes:nil error:NULL];
        if (made) {
                    [sFolder addPaths:@[tmpdir, @"/tmp/good.mp4"]];
            tcheck("folder: ignored (count == 1)", [sFolder count] == 1);
            tcheck("folder: one rejection", sFolder.lastRejectedCount == 1);
                    [NSFileManager.defaultManager removeItemAtPath:tmpdir error:NULL];
            } else {
            tcheck("folder: temp dir created", NO);
            }
        }

        /* ---- over six: only six accepted, extras reported ---- */
    VideoWallSelection *sOver = [VideoWallSelection new];
        [sOver addPaths:@[@"/tmp/o1.mp4", @"/tmp/o2.mp4", @"/tmp/o3.mp4",
                            @"/tmp/o4.mp4", @"/tmp/o5.mp4", @"/tmp/o6.mp4",
                            @"/tmp/o6b.mp4", @"/tmp/o8.mp4"]];
    tcheck("over: only 6 accepted", [sOver count] == 6);
    tcheck("over: selection complete", sOver.isComplete);
    tcheck("over: two extras rejected", sOver.lastRejectedCount == 2);

        /* ---- duplicates ignored by default (dedup) ---- */
    VideoWallSelection *sDup = [VideoWallSelection new];
        [sDup addPaths:@[@"/tmp/dup.mp4", @"/tmp/dup.mp4", @"/tmp/d2.mp4"]];
    tcheck("dedup: two unique kept", [sDup count] == 2);
    tcheck("dedup: one duplicate rejected", sDup.lastRejectedCount >= 1);

        /* ---- removing one disables Play again when fewer than six remain ---- */
        [sel addPaths:@[@"/tmp/clip2.m4v", @"/tmp/clip3.mov", @"/tmp/clip4.mkv",
                            @"/tmp/clip5.avi", @"/tmp/clip6.mp4"]];           /* now at six */
    tcheck("fill: complete again", sel.isComplete);
        [sel removeAtCell:2];
    tcheck("remove: count now 5", [sel count] == 5);
    tcheck("remove: Play disabled again", !sel.isComplete);

        /* ---- clear returns to the empty state ---- */
        [sel clear];
    tcheck("clear: count 0", [sel count] == 0);
    tcheck("clear: Play disabled", !sel.isComplete);
    tcheck("clear: status hint restored", sel.statusMessage.length > 0);

        /* ---- pressing Play with six hands the six paths, in order ---- */
    VideoWallSelection *sHand = [VideoWallSelection new];
    NSArray *ordered = @[@"/tmp/vA.mp4", @"/tmp/vB.m4v", @"/tmp/vC.mov",
                            @"/tmp/vD.mkv", @"/tmp/vE.avi", @"/tmp/vF.mp4"];
        [sHand addPaths:ordered];
    NSMutableArray *captured = [NSMutableArray array];
        __block BOOL fired = NO;
    sHand.onPlay = ^(NSArray<NSString *> *paths) {
        fired = YES;
        [captured addObjectsFromArray:paths];
        };
        [sHand play];
    tcheck("handoff: fired with six", fired == YES && captured.count == 6);
    tcheck("handoff: order == shown == dropped",
                [captured isEqualToArray:ordered] && [sHand.selectedPaths isEqualToArray:ordered]);

        /* ---- an incomplete selection must NOT fire the handoff ---- */
    VideoWallSelection *sPart = [VideoWallSelection new];
        [sPart addPaths:@[@"/tmp/p1.mp4"]];
        __block BOOL fired2 = NO;
    sPart.onPlay = ^(NSArray<NSString *> *paths) { fired2 = YES; };
        [sPart play];
    tcheck("incomplete: handoff not fired", fired2 == NO);

    fprintf(stderr,
                "[sixplayer] selection self-test: %d check(s), %d failed -> %s\n",
                g_test_total, g_test_fail, g_test_fail == 0 ? "PASS" : "FAIL");
    return g_test_fail == 0 ? 0 : 1;
}

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

        const char *controlSkip = getenv("CONTROL_SKIP_SECONDS");
        if (controlSkip && controlSkip[0]) {
            char *end = NULL;
            long seconds = strtol(controlSkip, &end, 10);
            if (end != controlSkip && seconds > 0) CONTROL_SKIP_MS = seconds * 1000;
        }

        const char *seltest = getenv("SIXPLAY_SELTEST");
        if (seltest && seltest[0]) {
                /* Headless selection model / handoff / routing check: no window, no
                * libVLC, no run loop -- just drive the testable seam. */
            int rc = runSelectionTests();
            fprintf(stderr, "[sixplayer] selection self-test rc=%d\n", rc);
            return rc;
            }

        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return g_exitcode;
}
