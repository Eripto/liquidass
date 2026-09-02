#import "LGIOS12PerfHUDView.h"
#import "LGIOS12LiveBackdropProvider.h"
#import "LGIOS12Quality.h"

@implementation LGIOS12PerfHUDView {
    UILabel *_headlineLabel;
    UILabel *_tableLabel;
    NSTimer *_timer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    self.layer.cornerRadius = 10.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.clipsToBounds = YES;

    _headlineLabel = [[UILabel alloc] init];
    _headlineLabel.font = [UIFont boldSystemFontOfSize:15.0];
    _headlineLabel.textColor = UIColor.whiteColor;
    _headlineLabel.textAlignment = NSTextAlignmentCenter;
    _headlineLabel.numberOfLines = 2;
    _headlineLabel.adjustsFontSizeToFitWidth = YES;
    _headlineLabel.minimumScaleFactor = 0.6;
    [self addSubview:_headlineLabel];

    _tableLabel = [[UILabel alloc] init];
    _tableLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:9.0]
        ?: [UIFont systemFontOfSize:9.0];
    _tableLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _tableLabel.numberOfLines = 0;
    [self addSubview:_tableLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = 8.0;
    CGFloat width = CGRectGetWidth(self.bounds) - pad * 2;
    _headlineLabel.frame = CGRectMake(pad, 6.0, width, 38.0);
    _tableLabel.frame = CGRectMake(pad, 48.0, width,
                                   CGRectGetHeight(self.bounds) - 52.0);
}

- (void)startSampling {
    [self stopSampling];
    // 2 Hz. The HUD's own string formatting is exactly the kind of per-frame
    // cost this phase is removing from the capture path, so it is kept well
    // below the capture rate and confined to Mode 9.
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                               target:self
                                             selector:@selector(sample)
                                             userInfo:nil
                                              repeats:YES];
    [self sample];
}

- (void)stopSampling {
    [_timer invalidate];
    _timer = nil;
}

- (void)dealloc {
    [_timer invalidate];
}

static NSString *LGIOS12HUDRow(NSString *name, LGIOS12Stat stat) {
    return [NSString stringWithFormat:@"%-22s %7.2f %7.2f\n",
        name.UTF8String, stat.ema, stat.worst];
}

- (void)sample {
    LGIOS12PerfSnapshot perf =
        [LGIOS12LiveBackdropProvider.sharedProvider performanceSnapshot];

    UIColor *fpsColor = perf.deliveredBackdropFPS >= 27.0
        ? [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0]
        : (perf.deliveredBackdropFPS >= 19.0
            ? [UIColor colorWithRed:1.0 green:0.85 blue:0.35 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0]);
    _headlineLabel.textColor = fpsColor;
    _headlineLabel.text = [NSString stringWithFormat:
        @"backdrop %.1f fps  ·  metal %.1f fps  ·  target %.0f\n%@",
        perf.deliveredBackdropFPS, perf.metalRedrawFPS, perf.targetFPS,
        [NSString stringWithFormat:@"quality %@ · scale %.2f · cap %.0f fps%@",
            LGIOS12QualityTierName((LGIOS12QualityTier)perf.qualityTier),
            perf.qualityEffectiveScale, perf.qualityMaxCaptureFPS,
            perf.legacyPath ? @" · LEGACY" : @""]];

    NSMutableString *table = [NSMutableString string];
    [table appendFormat:@"%-22s %7s %7s\n", "stage", "avg ms", "worst"];
    [table appendString:LGIOS12HUDRow(@"display-link gap", perf.displayLinkInterval)];
    [table appendString:LGIOS12HUDRow(@"window discovery", perf.windowDiscovery)];
    [table appendString:LGIOS12HUDRow(@"icon enumeration", perf.iconEnumeration)];
    [table appendString:LGIOS12HUDRow(@"strategy lookup", perf.strategyLookup)];
    [table appendString:LGIOS12HUDRow(@"icon composition", perf.iconComposition)];
    [table appendString:LGIOS12HUDRow(@"wallpaper comp", perf.wallpaperComposition)];
    [table appendString:LGIOS12HUDRow(@"bitmap context", perf.bitmapContext)];
    [table appendString:LGIOS12HUDRow(@"CGImage create", perf.imageCreation)];
    [table appendString:LGIOS12HUDRow(@"texture upload", perf.textureUpload)];
    [table appendString:LGIOS12HUDRow(@"TOTAL src frame", perf.totalSourceFrame)];
    [table appendString:LGIOS12HUDRow(@"metal redraw gap", perf.metalRedrawInterval)];
    [table appendString:LGIOS12HUDRow(@"texture age", perf.textureAge)];
    [table appendFormat:@"\nicons enum=%lu drawn=%lu prims=%lu\n",
        (unsigned long)perf.iconsEnumerated, (unsigned long)perf.iconsDrawn,
        (unsigned long)perf.primitivesDrawn];
    [table appendFormat:@"icon cache hit=%lu miss=%lu entries=%lu\n",
        (unsigned long)perf.iconCacheHits, (unsigned long)perf.iconCacheMisses,
        (unsigned long)perf.iconCacheEntries];
    [table appendFormat:@"backdrop texture %lux%lu\n",
        (unsigned long)perf.backdropTextureWidth,
        (unsigned long)perf.backdropTextureHeight];
    [table appendFormat:@"mem: capture buf %.2f MB · icon cache %.2f MB\n",
        perf.captureBufferBytes / 1048576.0, perf.iconCacheBytes / 1048576.0];
    [table appendFormat:@"dropped stale=%llu superseded=%llu captures=%llu",
        perf.droppedStale, perf.droppedSuperseded, perf.captureCount];
    _tableLabel.text = table;
}

@end
