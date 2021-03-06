//
//  ATKSimpleStackView.h
//  AppToolkit
//
//  Created by Rizwan Sattar on 8/3/15.
//
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ATKSimpleStackViewAlignment) {
    ATKSimpleStackViewAlignmentFill,
    ATKSimpleStackViewAlignmentCenter
};

typedef NS_ENUM(NSInteger, ATKSimpleStackViewDistribution) {
    ATKSimpleStackViewDistributionFill,
    ATKSimpleStackViewDistributionFillEqually,
};

@interface ATKSimpleStackView : UIView

@property (assign, nonatomic) ATKSimpleStackViewAlignment alignment;
@property (assign, nonatomic) IBInspectable NSInteger alignmentValue;

@property (assign, nonatomic) UILayoutConstraintAxis axis;
@property (assign, nonatomic) IBInspectable NSInteger axisValue;

@property (assign, nonatomic) IBInspectable BOOL layoutMarginsRelativeArrangement;
@property (assign, nonatomic) IBInspectable CGFloat spacing;
@property (assign, nonatomic) ATKSimpleStackViewDistribution distribution;
@property (assign, nonatomic) IBInspectable NSInteger distributionValue;

@property (readonly, nonatomic) NSArray *arrangedSubviews;

/// On iOS 8+ this is .layoutMargins, on iOS 7, it is our own margins
@property (assign, nonatomic) UIEdgeInsets lkMargins;

- (instancetype)initWithFrame:(CGRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithArrangedSubviews:(NSArray*)views NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

- (void) debug_printLayout;

@end
