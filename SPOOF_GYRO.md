#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <math.h>

// ============================================================================
// REALISTIC MOTION SIMULATION ENGINE
// ============================================================================

// Human motion characteristics
typedef struct {
    double tremorFreq;      // Hand tremor frequency (8-12 Hz)
    double tremorAmp;       // Tremor amplitude (0.5-2 degrees)
    double driftRate;       // Slow drift rate (degrees/second)
    double saccadeFreq;     // Micro-saccades frequency
    double breathFreq;      // Breathing frequency (0.2-0.3 Hz)
    double breathAmp;       // Breathing amplitude (1-3 degrees)
} HumanMotionParams;

// Current simulation state
static BOOL spoofingEnabled = YES;
static BOOL isTransitioning = NO;
static double transitionStartTime = 0;
static double transitionDuration = 0.0;

// Current target position (what the user wants)
typedef NS_ENUM(NSInteger, DevicePosition) {
    PositionFaceUpOnTable = 0,
    PositionFaceDownOnTable,
    PositionHeldPortrait,
    PositionHeldPortraitTiltedUp,
    PositionHeldPortraitTiltedDown,
    PositionHeldLandscapeLeft,
    PositionHeldLandscapeRight,
    PositionInPocket,
    PositionBeingPickedUp,
    PositionBeingPutDown,
    PositionWalking,
    PositionWalkingWithTilt,
    PositionLookingAround
};

// Current simulated values (with noise)
static double currentPitch = 0.0;
static double currentRoll = 0.0;
static double currentYaw = 0.0;
static double currentGravityZ = -1.0;

// Target values for smooth interpolation
static double targetPitch = 0.0;
static double targetRoll = 0.0;
static double targetYaw = 0.0;
static double targetGravityZ = -1.0;

// Noise state
static double noisePhase = 0.0;
static double driftPhase = 0.0;
static double breathPhase = 0.0;
static double lastUpdateTime = 0;

// ============================================================================
// NATURAL NOISE GENERATORS
// ============================================================================

// 1/f pink noise for realistic sensor drift
static double pinkNoise(double *state) {
    static double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0;
    static double white = 0;
    
    white = (double)arc4random() / UINT32_MAX * 2.0 - 1.0;
    b0 = 0.99886 * b0 + white * 0.0555179;
    b1 = 0.99332 * b1 + white * 0.0750759;
    b2 = 0.96900 * b2 + white * 0.1538520;
    b3 = 0.86650 * b3 + white * 0.3104856;
    b4 = 0.55000 * b4 + white * 0.5329522;
    b5 = -0.7616 * b5 - white * 0.0168980;
    
    double pink = b0 + b1 + b2 + b3 + b4 + b5 + b5 * 0.5362;
    pink *= 0.11; // Scale for realistic motion
    return pink;
}

// Hand tremor (8-12 Hz Gaussian)
static double handTremor(double time, double amplitude) {
    double tremor = 0;
    tremor += amplitude * 0.6 * sin(2 * M_PI * 9.5 * time);      // Main frequency ~9.5 Hz
    tremor += amplitude * 0.3 * sin(2 * M_PI * 11.2 * time);     // Secondary
    tremor += amplitude * 0.1 * sin(2 * M_PI * 8.3 * time);      // Tertiary
    return tremor * (0.8 + 0.4 * sin(time * 0.5));               // Amplitude modulation
}

// Breathing motion (0.2-0.3 Hz)
static double breathingMotion(double time, double amplitude) {
    return amplitude * sin(2 * M_PI * 0.25 * time) * 
           (1 + 0.2 * sin(2 * M_PI * 0.05 * time));  // Irregular breathing
}

// Natural saccades (small rapid movements when holding)
static double microSaccades(double time) {
    // Saccades occur randomly ~1-2 times per second
    double saccade = 0;
    double t = fmod(time, 1.0);
    if (t < 0.05) { // 50ms saccade
        saccade = (double)arc4random() / UINT32_MAX * 0.8 - 0.4;
    }
    return saccade;
}

// Slow drift (natural unconscious movement)
static double slowDrift(double time, double rate) {
    return rate * time + 0.5 * sin(2 * M_PI * 0.07 * time);
}

// ============================================================================
// POSITION-SPECIFIC SIMULATION
// ============================================================================

static void updateSimulationForPosition(DevicePosition position, double elapsedTime) {
    static double pickupProgress = 0;
    static double walkPhase = 0;
    
    // Base values (without noise)
    double basePitch = 0, baseRoll = 0, baseGravityZ = -1;
    HumanMotionParams params = {0};
    
    switch (position) {
        case PositionFaceUpOnTable:
            // Phone completely flat on table - minimal movement
            basePitch = 0;
            baseRoll = 0;
            baseGravityZ = -1.0;
            params.tremorAmp = 0.1;      // Almost no tremor
            params.tremorFreq = 0;
            params.driftRate = 0.02;      // Very slow drift from vibrations
            params.breathAmp = 0.05;
            params.breathFreq = 0.2;
            break;
            
        case PositionFaceDownOnTable:
            basePitch = 180;
            baseRoll = 0;
            baseGravityZ = 1.0;
            params.tremorAmp = 0.1;
            params.driftRate = 0.02;
            params.breathAmp = 0.05;
            break;
            
        case PositionInPocket:
            // In pocket - chaotic motion but constrained
            basePitch = -30 + pinkNoise(NULL) * 20;
            baseRoll = 10 + pinkNoise(NULL) * 30;
            baseGravityZ = -0.87;
            params.tremorAmp = 1.5;       // Walking motion
            params.tremorFreq = 2.0;      // Step frequency
            params.driftRate = 5.0;
            params.breathAmp = 2.0;
            break;
            
        case PositionHeldPortrait:
            // Normal holding - slight tilt toward user
            basePitch = -12;
            baseRoll = 0;
            baseGravityZ = -0.98;
            params.tremorAmp = 0.6;       // Noticeable hand tremor
            params.tremorFreq = 9.5;
            params.driftRate = 0.15;      // Slow drift while holding
            params.breathAmp = 1.2;       // Breathing causes ~1 deg movement
            params.breathFreq = 0.25;
            break;
            
        case PositionHeldPortraitTiltedUp:
            // Pointing at sky (like checking something high)
            basePitch = -55;
            baseRoll = 0;
            baseGravityZ = -0.57;
            params.tremorAmp = 1.2;       // More tremor when arm extended
            params.tremorFreq = 10.5;
            params.driftRate = 0.3;
            params.breathAmp = 2.0;       // Breathing more noticeable
            break;
            
        case PositionHeldPortraitTiltedDown:
            // Pointing at ground (looking down)
            basePitch = 38;
            baseRoll = 0;
            baseGravityZ = -0.79;
            params.tremorAmp = 0.8;
            params.breathAmp = 1.5;
            break;
            
        case PositionHeldLandscapeLeft:
            basePitch = -8;
            baseRoll = 88;
            baseGravityZ = -0.14;
            params.tremorAmp = 0.7;
            params.breathAmp = 1.3;
            break;
            
        case PositionHeldLandscapeRight:
            basePitch = -8;
            baseRoll = -88;
            baseGravityZ = -0.14;
            params.tremorAmp = 0.7;
            params.breathAmp = 1.3;
            break;
            
        case PositionWalking:
            // Natural walking motion
            walkPhase += elapsedTime * 2.0;  // ~2 steps per second
            basePitch = -15 + 3 * sin(walkPhase * M_PI);
            baseRoll = 4 * sin(walkPhase * M_PI * 2);
            baseGravityZ = -0.95;
            params.tremorAmp = 1.5;
            params.breathAmp = 2.5;
            params.driftRate = 0.5;
            break;
            
        case PositionWalkingWithTilt:
            // Walking while looking at phone
            walkPhase += elapsedTime * 2.0;
            basePitch = -25 + 2 * sin(walkPhase * M_PI);
            baseRoll = 2 * sin(walkPhase * M_PI * 2);
            baseGravityZ = -0.91;
            params.tremorAmp = 1.2;
            params.breathAmp = 1.8;
            break;
            
        case PositionLookingAround:
            // Simulating turning head/phone to look around
            basePitch = -10 + 5 * sin(elapsedTime * 0.5);
            baseYaw = 15 * sin(elapsedTime * 0.3);
            baseRoll = 2 * sin(elapsedTime * 0.7);
            params.tremorAmp = 0.9;
            params.driftRate = 0.2;
            break;
            
        case PositionBeingPickedUp:
            // Smooth transition from table to hand
            pickupProgress += elapsedTime * 1.5;  // 0.66 sec pickup
            if (pickupProgress > 1) pickupProgress = 1;
            
            // Ease in-out curve
            double ease = pickupProgress < 0.5 ? 
                          2 * pickupProgress * pickupProgress : 
                          1 - pow(-2 * pickupProgress + 2, 2) / 2;
            
            basePitch = -12 * ease;
            baseRoll = 0;
            baseGravityZ = -1.0 + (0.02 * ease);
            
            // Add extra motion during pickup
            basePitch += 2 * sin(elapsedTime * 8) * (1 - pickupProgress);
            
            if (pickupProgress >= 1) {
                isTransitioning = NO;
                pickupProgress = 0;
            }
            break;
            
        case PositionBeingPutDown:
            pickupProgress += elapsedTime * 1.2;
            if (pickupProgress > 1) pickupProgress = 1;
            
            ease = pickupProgress < 0.5 ? 
                   2 * pickupProgress * pickupProgress : 
                   1 - pow(-2 * pickupProgress + 2, 2) / 2;
            
            basePitch = -12 * (1 - ease);
            baseRoll = 0;
            baseGravityZ = -0.98 + (0.02 * ease);
            
            if (pickupProgress >= 1) {
                isTransitioning = NO;
                pickupProgress = 0;
            }
            break;
    }
    
    // Apply realistic noise to base values
    double time = CACurrentMediaTime();
    
    // Hand tremor (only when held, not on table)
    double tremor = (params.tremorAmp > 0.1) ? 
                    handTremor(time, params.tremorAmp) : 0;
    
    // Breathing motion
    double breath = breathingMotion(time, params.breathAmp);
    
    // Pink noise for natural randomness
    double pinkNoiseX = pinkNoise(NULL) * 0.3;
    double pinkNoiseY = pinkNoise(NULL) * 0.3;
    
    // Micro-saccades (rapid eye/hand movements)
    double saccade = microSaccades(time) * 0.5;
    
    // Slow drift
    double drift = slowDrift(time, params.driftRate) * 0.1;
    
    // Combine all noise sources
    double noisePitch = tremor * 0.7 + breath * 0.2 + pinkNoiseX + saccade * 0.3 + drift * 0.1;
    double noiseRoll = tremor * 0.5 + breath * 0.15 + pinkNoiseY + saccade * 0.2;
    double noiseYaw = tremor * 0.3 + drift * 0.2 + pinkNoise(NULL) * 0.2;
    
    // Apply to target values
    targetPitch = basePitch + noisePitch;
    targetRoll = baseRoll + noiseRoll;
    targetYaw = baseYaw + noiseYaw;
    targetGravityZ = baseGravityZ + (pinkNoise(NULL) * 0.005);
    
    // Clamp to realistic ranges
    targetPitch = fmax(-90, fmin(90, targetPitch));
    targetRoll = fmax(-180, fmin(180, targetRoll));
    targetGravityZ = fmax(-1.0, fmin(1.0, targetGravityZ));
}

// ============================================================================
// SMOOTH INTERPOLATION ENGINE
// ============================================================================

static void interpolateValues(double deltaTime) {
    // Smooth interpolation with easing
    double smoothFactor = fmin(1.0, deltaTime * 15);  // 15 Hz response
    
    // Critically damped for natural motion
    currentPitch = currentPitch * (1 - smoothFactor) + targetPitch * smoothFactor;
    currentRoll = currentRoll * (1 - smoothFactor) + targetRoll * smoothFactor;
    currentYaw = currentYaw * (1 - smoothFactor) + targetYaw * smoothFactor;
    currentGravityZ = currentGravityZ * (1 - smoothFactor) + targetGravityZ * smoothFactor;
}

// ============================================================================
// EXPORTED CONTROL FUNCTIONS
// ============================================================================

static DevicePosition currentCommand = PositionFaceUpOnTable;

void setDevicePosition(DevicePosition position) {
    currentCommand = position;
    isTransitioning = (position == PositionBeingPickedUp || position == PositionBeingPutDown);
    
    NSLog(@"[MotionSpoof] Setting position to: %ld", (long)position);
}

void startRealisticSimulation() {
    lastUpdateTime = CACurrentMediaTime();
    spoofingEnabled = YES;
    currentPitch = 0;
    currentRoll = 0;
    currentYaw = 0;
    currentGravityZ = -1;
    targetPitch = 0;
    targetRoll = 0;
    targetYaw = 0;
    targetGravityZ = -1;
}

// ============================================================================
// CORE MOTION HOOKS
// ============================================================================

%hook CMMotionManager

- (CMDeviceMotion *)deviceMotion {
    if (!spoofingEnabled) return %orig;
    
    // Update simulation
    double now = CACurrentMediaTime();
    double deltaTime = (lastUpdateTime > 0) ? (now - lastUpdateTime) : 0.016;
    deltaTime = fmin(0.033, deltaTime);  // Cap at 30fps
    lastUpdateTime = now;
    
    updateSimulationForPosition(currentCommand, deltaTime);
    interpolateValues(deltaTime);
    
    // Create spoofed CMAttitude
    CMAttitude *spoofedAttitude = [self createRealisticAttitude];
    
    // Create spoofed CMDeviceMotion
    CMDeviceMotion *spoofedMotion = [[NSClassFromString(@"CMDeviceMotion") alloc] init];
    [spoofedMotion setValue:spoofedAttitude forKey:@"_attitude"];
    
    // Gravity with noise
    CMAcceleration gravity;
    gravity.x = 0;
    gravity.y = 0;
    gravity.z = currentGravityZ;
    [spoofedMotion setValue:[NSValue valueWithCMAcceleration:gravity] forKey:@"_gravity"];
    
    // User acceleration (natural micro-movements)
    CMAcceleration userAccel;
    userAccel.x = pinkNoise(NULL) * 0.05;
    userAccel.y = pinkNoise(NULL) * 0.05;
    userAccel.z = pinkNoise(NULL) * 0.03;
    [spoofedMotion setValue:[NSValue valueWithCMAcceleration:userAccel] forKey:@"_userAcceleration"];
    
    // Rotation rate (gyroscope) with realistic noise
    CMRotationRate rotationRate;
    double time = now;
    rotationRate.x = handTremor(time, 0.3) * 0.5 + pinkNoise(NULL) * 0.02;
    rotationRate.y = handTremor(time, 0.25) * 0.5 + pinkNoise(NULL) * 0.02;
    rotationRate.z = pinkNoise(NULL) * 0.01;
    [spoofedMotion setValue:[NSValue valueWithCMRotationRate:rotationRate] forKey:@"_rotationRate"];
    
    // Magnetic field (simulate earth's field with noise)
    CMMagneticField magneticField;
    magneticField.x = 25 + pinkNoise(NULL) * 2;
    magneticField.y = -5 + pinkNoise(NULL) * 2;
    magneticField.z = 45 + pinkNoise(NULL) * 2;
    [spoofedMotion setValue:[NSValue valueWithCMMagneticField:magneticField] forKey:@"_magneticField"];
    
    return spoofedMotion;
}

- (CMAttitude *)createRealisticAttitude {
    CMAttitude *attitude = [[NSClassFromString(@"CMAttitude") alloc] init];
    
    // Convert Euler angles to quaternion
    double pitchRad = currentPitch * M_PI / 180.0;
    double rollRad = currentRoll * M_PI / 180.0;
    double yawRad = currentYaw * M_PI / 180.0;
    
    // Quaternion from Euler (ZYX order)
    double cy = cos(yawRad * 0.5);
    double sy = sin(yawRad * 0.5);
    double cp = cos(pitchRad * 0.5);
    double sp = sin(pitchRad * 0.5);
    double cr = cos(rollRad * 0.5);
    double sr = sin(rollRad * 0.5);
    
    double qw = cy * cp * cr + sy * sp * sr;
    double qx = cy * cp * sr - sy * sp * cr;
    double qy = sy * cp * sr + cy * sp * cr;
    double qz = sy * cp * cr - cy * sp * sr;
    
    [attitude setValue:@(qw) forKey:@"_quaternionW"];
    [attitude setValue:@(qx) forKey:@"_quaternionX"];
    [attitude setValue:@(qy) forKey:@"_quaternionY"];
    [attitude setValue:@(qz) forKey:@"_quaternionZ"];
    
    [attitude setValue:@(pitchRad) forKey:@"_pitch"];
    [attitude setValue:@(rollRad) forKey:@"_roll"];
    [attitude setValue:@(yawRad) forKey:@"_yaw"];
    
    // Add rotation matrix for completeness
    double r11 = cos(yawRad) * cos(pitchRad);
    double r12 = cos(yawRad) * sin(pitchRad) * sin(rollRad) - sin(yawRad) * cos(rollRad);
    double r13 = cos(yawRad) * sin(pitchRad) * cos(rollRad) + sin(yawRad) * sin(rollRad);
    double r21 = sin(yawRad) * cos(pitchRad);
    double r22 = sin(yawRad) * sin(pitchRad) * sin(rollRad) + cos(yawRad) * cos(rollRad);
    double r23 = sin(yawRad) * sin(pitchRad) * cos(rollRad) - cos(yawRad) * sin(rollRad);
    double r31 = -sin(pitchRad);
    double r32 = cos(pitchRad) * sin(rollRad);
    double r33 = cos(pitchRad) * cos(rollRad);
    
    CMRotationMatrix rotationMatrix = {
        r11, r12, r13,
        r21, r22, r23,
        r31, r32, r33
    };
    [attitude setValue:[NSValue valueWithCMRotationMatrix:rotationMatrix] forKey:@"_rotationMatrix"];
    
    return attitude;
}

%end

// ============================================================================
// FLOATING CONTROL UI
// ============================================================================

@interface MotionControlWindow : UIWindow
@end

%hook UIApplication
- (void)applicationDidFinishLaunching:(UIApplication *)app {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MotionControlWindow *control = [[MotionControlWindow alloc] init];
        control.hidden = NO;
        startRealisticSimulation();
    });
}
%end

@implementation MotionControlWindow

- (instancetype)init {
    CGRect frame = CGRectMake(10, 100, 160, 420);
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 2;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor darkGrayColor].CGColor;
        
        // Make draggable
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        
        UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(5, 35, 150, 375)];
        scrollView.showsVerticalScrollIndicator = YES;
        
        UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 140, 400)];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        stack.distribution = UIStackViewDistributionFillEqually;
        
        NSArray *positions = @[
            @{@"name": @"📱 Face Up (Table)", @"value": @(PositionFaceUpOnTable)},
            @{@"name": @"📱 Face Down", @"value": @(PositionFaceDownOnTable)},
            @{@"name": @"👖 In Pocket", @"value": @(PositionInPocket)},
            @{@"name": @"👆 Normal Hold", @"value": @(PositionHeldPortrait)},
            @{@"name": @"⬆️ Tilted Up", @"value": @(PositionHeldPortraitTiltedUp)},
            @{@"name": @"⬇️ Tilted Down", @"value": @(PositionHeldPortraitTiltedDown)},
            @{@"name": @"📱 Landscape L", @"value": @(PositionHeldLandscapeLeft)},
            @{@"name": @"📱 Landscape R", @"value": @(PositionHeldLandscapeRight)},
            @{@"name": @"🚶 Walking", @"value": @(PositionWalking)},
            @{@"name": @"🚶‍♂️ Walking/Phone", @"value": @(PositionWalkingWithTilt)},
            @{@"name": @"👀 Looking Around", @"value": @(PositionLookingAround)},
            @{@"name": @"🤚 Pick Up", @"value": @(PositionBeingPickedUp)},
            @{@"name": @"👇 Put Down", @"value": @(PositionBeingPutDown)}
        ];
        
        for (NSDictionary *pos in positions) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            [btn setTitle:pos[@"name"] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:11];
            btn.backgroundColor = [[UIColor colorWithRed:0.2 green:0.4 blue:0.6 alpha:1] colorWithAlphaComponent:0.7];
            btn.layer.cornerRadius = 5;
            btn.tag = [pos[@"value"] integerValue];
            [btn addTarget:self action:@selector(positionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [stack addArrangedSubview:btn];
        }
        
        [scrollView addSubview:stack];
        scrollView.contentSize = CGSizeMake(140, positions.count * 38);
        [self addSubview:scrollView];
        
        // Title bar
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, 160, 22)];
        title.text = @"🎯 Real Motion Spoofer";
        title.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
        title.font = [UIFont boldSystemFontOfSize:11];
        title.textAlignment = NSTextAlignmentCenter;
        [self addSubview:title];
        
        // Status indicator
        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(0, frame.size.height - 22, 160, 18)];
        status.text = @"● SIMULATING REAL MOTION";
        status.textColor = [UIColor greenColor];
        status.font = [UIFont systemFontOfSize:8];
        status.textAlignment = NSTextAlignmentCenter;
        [self addSubview:status];
        
        // Close button
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(135, 5, 20, 20);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.superview];
}

- (void)positionButtonTapped:(UIButton *)sender {
    setDevicePosition((DevicePosition)sender.tag);
}

- (void)close {
    self.hidden = YES;
}

@end

%ctor {
    NSLog(@"[MotionSpoof] Loaded - Realistic motion simulation active");
}