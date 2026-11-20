#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EmulatorViewController : UIViewController

@property (nonatomic, copy) NSString *machineId;
@property (nonatomic, copy) NSString *machineName;
@property (nonatomic, copy) NSString *stateDirPath;
@property (nonatomic, copy) NSString *baseDirPath;
@property (nonatomic, assign) NSInteger screenWidth;
@property (nonatomic, assign) NSInteger screenHeight;
@property (nonatomic, assign) NSInteger screenScale;
@property (nonatomic, copy, nullable) void (^onEngineProcessConsumed)(void);

- (instancetype)initWithMachineId:(NSString *)machineId
                      machineName:(NSString *)machineName
                     stateDirPath:(NSString *)stateDirPath
                      baseDirPath:(NSString *)baseDirPath;

- (void)stopEmulation;

@end

NS_ASSUME_NONNULL_END
