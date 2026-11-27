//
//  AbsoluteTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//
//  Touchscreen mode, reworked to behave like a native touch app. Nothing is pressed
//  on the host until the gesture is known:
//
//    tap               -> cursor moves to the finger, then a clean click (press, gap, release)
//    touch + drag      -> press where the finger landed, let the host register it, then follow
//                         the finger; release on lift
//    touch + hold      -> hover only (tooltips show); lifting does not click.
//                         Moving after the hold turns it into a drag.
//    two-finger tap    -> right click at the first finger
//    two-finger drag / pinch / three fingers -> handled by StreamView (scroll, zoom, keyboard)
//

#import "AbsoluteTouchHandler.h"

#include <Limelight.h>

// Movement (in points) before a touch counts as a drag instead of a tap or hold
#define DRAG_SLOP 10.0

// How long a still finger is a tap; held longer it becomes a hover (inspect)
#define HOLD_DELAY 0.300

// After pressing for a drag, keep the cursor on the press point this long so the host
// registers the press on the item under the finger before the item starts moving
#define DRAG_PRESS_SETTLE 0.040

// Gap between press and release for a tap, so the host sees them in different frames
#define CLICK_RELEASE_DELAY 0.035

// Delay before releasing at the end of a drag, so the last move lands first
#define DRAG_RELEASE_DELAY 0.025

// A two-finger tap must be this short and this still to become a right click
#define TWO_FINGER_TAP_MAX_DURATION 0.300
#define TWO_FINGER_TAP_MAX_MOVEMENT 15.0

// Double tap: a second tap this soon and this close reuses the first tap's position,
// so a double click lands on the same spot
#define DOUBLE_TAP_DELAY 0.300
#define DOUBLE_TAP_DISTANCE 20.0

typedef NS_ENUM(NSInteger, TouchGesture) {
    TouchGestureNone,
    TouchGesturePending,     // finger down, not yet a tap, drag or hold
    TouchGestureHolding,     // held still: hovering only
    TouchGestureDragging,    // left button is down and following the finger
    TouchGestureMultiFinger, // more than one finger: StreamView handles it, maybe a right click
};

@implementation AbsoluteTouchHandler {
    StreamView* view;

    TouchGesture gesture;
    UITouch* primaryTouch;
    CGPoint downLocation;       // where the gesture's cursor position is (view points)
    NSTimeInterval downTime;

    NSTimer* holdTimer;
    NSTimeInterval pressTime;   // when the drag's press was sent

    // Two-finger tap tracking
    NSTimeInterval multiStartTime;
    BOOL multiMoved;
    NSMutableDictionary<NSValue*, NSValue*>* multiStarts;

    // Double tap tracking
    NSTimeInterval lastTapTime;
    CGPoint lastTapLocation;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    self->gesture = TouchGestureNone;
    self->multiStarts = [[NSMutableDictionary alloc] init];
    return self;
}

static CGFloat distanceBetween(CGPoint a, CGPoint b) {
    return hypot(a.x - b.x, a.y - b.y);
}

#pragma mark - Mouse output

- (void)moveCursorTo:(CGPoint)location {
    [view updateCursorLocation:location isMouse:NO];
}

- (void)sendClick:(int)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CLICK_RELEASE_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    });
}

- (void)cancelHoldTimer {
    [holdTimer invalidate];
    holdTimer = nil;
}

#pragma mark - Gesture transitions

- (void)onHoldTimer:(NSTimer*)timer {
    holdTimer = nil;
    if (gesture == TouchGesturePending) {
        // Held still: just hover so the host shows its tooltip
        gesture = TouchGestureHolding;
    }
}

- (void)beginDrag {
    [self cancelHoldTimer];
    // The cursor is still on the point where the finger landed: press there
    [self moveCursorTo:downLocation];
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    pressTime = CACurrentMediaTime();
    gesture = TouchGestureDragging;
}

- (void)endDrag {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DRAG_RELEASE_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    });
}

// A second finger landed during a single-finger gesture
- (void)switchToMultiFinger:(UIEvent*)event {
    [self cancelHoldTimer];
    if (gesture == TouchGestureDragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    // Only a gesture that started as a fresh touch can become a two-finger tap
    BOOL fresh = (gesture == TouchGesturePending || gesture == TouchGestureNone);
    gesture = TouchGestureMultiFinger;
    multiStartTime = fresh ? downTime : 0;
    multiMoved = !fresh;
    [multiStarts removeAllObjects];
    for (UITouch* t in [event allTouches]) {
        multiStarts[[NSValue valueWithNonretainedObject:t]] = [NSValue valueWithCGPoint:[t locationInView:view]];
    }
}

#pragma mark - UIResponder

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([[event allTouches] count] > 1) {
        if (gesture != TouchGestureMultiFinger) {
            [self switchToMultiFinger:event];
        }
        else {
            for (UITouch* t in touches) {
                multiStarts[[NSValue valueWithNonretainedObject:t]] = [NSValue valueWithCGPoint:[t locationInView:view]];
            }
            if ([[event allTouches] count] > 2) {
                multiMoved = YES; // three fingers: keyboard or panning, never a right click
            }
        }
        return;
    }

    UITouch* touch = [touches anyObject];
    CGPoint location = [touch locationInView:view];

    // A quick second tap near the first lands on exactly the same spot (double click)
    if (touch.timestamp - lastTapTime < DOUBLE_TAP_DELAY && distanceBetween(location, lastTapLocation) < DOUBLE_TAP_DISTANCE) {
        location = lastTapLocation;
    }

    primaryTouch = touch;
    downLocation = location;
    downTime = touch.timestamp;
    gesture = TouchGesturePending;

    // Hover first: the host sees the cursor arrive before anything is pressed
    [self moveCursorTo:location];

    [self cancelHoldTimer];
    holdTimer = [NSTimer scheduledTimerWithTimeInterval:HOLD_DELAY
                                                 target:self
                                               selector:@selector(onHoldTimer:)
                                               userInfo:nil
                                                repeats:NO];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (gesture == TouchGestureMultiFinger || [[event allTouches] count] > 1) {
        if (gesture != TouchGestureMultiFinger) {
            [self switchToMultiFinger:event];
        }
        for (UITouch* t in touches) {
            NSValue* start = multiStarts[[NSValue valueWithNonretainedObject:t]];
            if (start != nil && distanceBetween([t locationInView:view], start.CGPointValue) > TWO_FINGER_TAP_MAX_MOVEMENT) {
                multiMoved = YES;
            }
        }
        return;
    }

    UITouch* touch = primaryTouch ?: [touches anyObject];
    CGPoint location = [touch locationInView:view];

    switch (gesture) {
        case TouchGesturePending:
        case TouchGestureHolding:
            // Small jitter is ignored, so a tap or a hold stays exactly where it landed
            if (distanceBetween(location, downLocation) > DRAG_SLOP) {
                [self beginDrag];
            }
            break;

        case TouchGestureDragging:
            // Let the press settle on the item before it starts to move
            if (CACurrentMediaTime() - pressTime >= DRAG_PRESS_SETTLE) {
                [self moveCursorTo:location];
            }
            break;

        default:
            break;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    // Act only when the last finger lifts
    if ([[event allTouches] count] != [touches count]) {
        return;
    }

    UITouch* touch = [touches anyObject];
    [self cancelHoldTimer];

    switch (gesture) {
        case TouchGesturePending:
            // A quick, still tap: click where the finger landed
            [self moveCursorTo:downLocation];
            [self sendClick:BUTTON_LEFT];
            lastTapTime = touch.timestamp;
            lastTapLocation = downLocation;
            break;

        case TouchGestureDragging:
            [self moveCursorTo:[(primaryTouch ?: touch) locationInView:view]];
            [self endDrag];
            break;

        case TouchGestureMultiFinger:
            if (!multiMoved && multiStartTime > 0 &&
                touch.timestamp - multiStartTime < TWO_FINGER_TAP_MAX_DURATION) {
                [self moveCursorTo:downLocation];
                [self sendClick:BUTTON_RIGHT];
            }
            break;

        case TouchGestureHolding:
            // Inspect only: leave the cursor hovering, no click
        default:
            break;
    }

    gesture = TouchGestureNone;
    primaryTouch = nil;
    [multiStarts removeAllObjects];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    // The system took the touches (e.g. a system gesture): never leave a button held
    [self cancelHoldTimer];
    if (gesture == TouchGestureDragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    if ([[event allTouches] count] == [touches count]) {
        gesture = TouchGestureNone;
        primaryTouch = nil;
        [multiStarts removeAllObjects];
    }
}

@end
