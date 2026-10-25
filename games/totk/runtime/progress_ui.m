#import "progress_sync.h"
#import "progress_errors.h"
#include <TargetConditionals.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *versionTitle(NSDictionary *record) {
    NSDate *date=[NSDate dateWithTimeIntervalSince1970:[record[@"created"] doubleValue]];
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateStyle=NSDateFormatterShortStyle;formatter.timeStyle=NSDateFormatterMediumStyle;
    NSString *kind=[record[@"kind"] isEqual:@"restore"]?@"恢复记录":[record[@"kind"] isEqual:@"choice"]?@"已选择进度":@"游戏内存档";
    return [NSString stringWithFormat:@"记录于 %@ · %@",[formatter stringFromDate:date],kind];
}
static NSString *versionDetail(NSDictionary *record) {
    NSString *device=record[@"deviceName"]?:record[@"device"];
    if ([[NSUUID alloc] initWithUUIDString:device]) device=@"其他设备";
    return [NSString stringWithFormat:@"%@ · 游戏 %@ · %@",device?:@"设备",record[@"version"]?:@"—",[NSByteCountFormatter stringFromByteCount:[record[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
}
static NSString *statusText(NSDictionary *state) {
    NSMutableArray *lines=[NSMutableArray arrayWithObject:state[@"status"]?:@"正在准备进度列表…"];
    if(state[@"enabled"]&&![state[@"enabled"] boolValue]&&![state[@"status"] containsString:@"云同步已暂停"])[lines addObject:@"云同步已暂停，本机保存和历史继续保留。"];
    if([state[@"pendingAction"] count])[lines addObject:@"已安排载入所选进度；请退出并重新打开游戏，可以取消安排。"];
    else if([state[@"restartToContinue"] boolValue]&&![state[@"status"] containsString:@"重新打开"])[lines addObject:@"有新进度可接续，请退出并重新打开游戏。"];
    NSMutableArray *names=[NSMutableArray new];
    for(NSDictionary *receipt in state[@"currentReceivers"])[names addObject:receipt[@"deviceName"]?:@"其他设备"];
    if(names.count)[lines addObject:[NSString stringWithFormat:@"已接收当前版本：%@。接收不代表已经载入游玩。",[names componentsJoinedByString:@"、"]]];
    if([state[@"waitingBackups"] unsignedIntegerValue])[lines addObject:@"有命名备份正在等待游戏保存完成。"];
    if(state[@"historyRecordBytes"])[lines addObject:[NSString stringWithFormat:@"本机历史记录文件：%@；首版持续保留，不自动清理。",[NSByteCountFormatter stringFromByteCount:[state[@"historyRecordBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]]];
    return [lines componentsJoinedByString:@"\n"];
}

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

static UIViewController *topController(id host) {
    UIViewController *vc=[host isKindOfClass:UIViewController.class]?host:nil;
    if (!vc) for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class])
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if(window.isKeyWindow)vc=window.rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) vc=((UINavigationController *)vc).visibleViewController;
    return vc;
}
static void showMessage(id host, NSString *message) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"游戏进度" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [topController(host) presentViewController:alert animated:YES completion:nil];
}
static void promptName(id host, NSString *initial, void (^completion)(NSString *)) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"命名备份" message:@"保留这次已完成的游戏存档。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=initial;field.placeholder=@"例如：最终战之前";field.accessibilityLabel=@"备份名称";}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保留备份" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;completion(alert.textFields.firstObject.text?:@"");}]];
    [topController(host) presentViewController:alert animated:YES completion:nil];
}
@interface TOTKProgressManager : UITableViewController
@property(strong) TOTKProgressSync *sync;
@property(copy) void (^enterGame)(void);
@end
@implementation TOTKProgressManager
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"游戏进度";
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight=60;
    self.navigationItem.rightBarButtonItem=self.enterGame?[[UIBarButtonItem alloc] initWithTitle:@"进入游戏" style:UIBarButtonItemStylePlain target:self action:@selector(close)]:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshView) name:TOTKProgressDidChange object:self.sync];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshView) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self refreshView];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)close {
    if(self.enterGame)self.enterGame();
    else [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)refreshView {
    if(self.enterGame)self.navigationItem.rightBarButtonItem.enabled=[self.sync.viewState[@"localPrepared"] boolValue];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 4;}
- (NSArray *)actions {
    NSMutableArray *actions=[NSMutableArray arrayWithArray:@[@"folder",@"refresh",@"backup",@"toggle"]];
    if([self.sync.viewState[@"pendingAction"] count])[actions addObject:@"cancel"];
    if([self.sync.viewState[@"canContinueLocal"] boolValue])[actions addObject:@"continue"];
    return actions;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;NSDictionary *state=self.sync.viewState;
    if(section==0)return self.actions.count;
    if(section==1)return [state[@"heads"] count]>1?[state[@"heads"] count]:0;
    return [state[section==2?@"versions":@"backups"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;return @[@"同步与当前进度",@"待选择进度（各份均保留）",@"历史版本",@"命名备份"][section];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *header=[tableView dequeueReusableHeaderFooterViewWithIdentifier:@"progress-section"];
    if(!header)header=[[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"progress-section"];
    UIListContentConfiguration *content=[UIListContentConfiguration groupedHeaderConfiguration];
    NSString *title=[self tableView:tableView titleForHeaderInSection:section];
    if(section==0) {
        // One system section header keeps status and title in the same safe-area column.
        NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:[statusText(self.sync.viewState) stringByAppendingString:@"\n\n"] attributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleBody],NSForegroundColorAttributeName:UIColor.labelColor}];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],NSForegroundColorAttributeName:UIColor.secondaryLabelColor}]];
        content.attributedText=text;
    } else content.text=title;
    content.textProperties.numberOfLines=0;header.contentConfiguration=content;
    return header;
}
- (NSDictionary *)recordForIndex:(NSIndexPath *)index {
    NSDictionary *state=self.sync.viewState;
    if(index.section==1) {
        NSString *key=state[@"heads"][index.row];for(NSDictionary *r in state[@"versions"])if([r[@"id"] isEqual:key])return r;
    }
    return index.section>=2?state[index.section==2?@"versions":@"backups"][index.row]:nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"progress"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"progress"];
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(index.section==0) {
        NSDictionary *titles=@{@"folder":@"选择 iCloud 同步文件夹",@"refresh":@"立即检查同步",@"backup":@"为当前存档命名备份",@"toggle":[self.sync.viewState[@"enabled"] boolValue]?@"暂停云同步":@"开启云同步",@"cancel":@"取消下次载入安排",@"continue":@"使用本机进度继续"};
        cell.textLabel.text=titles[self.actions[index.row]];cell.detailTextLabel.text=nil;
    }
    else {
        NSDictionary *r=[self recordForIndex:index];
        cell.textLabel.text=index.section==3?r[@"name"]:versionTitle(r);
        cell.detailTextLabel.text=index.section==3?@"固定保留，可恢复或改名":versionDetail(r);
        if([r[@"id"] isEqual:self.sync.viewState[@"base"]])cell.accessoryType=UITableViewCellAccessoryCheckmark;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    if(index.section==0) {
        NSArray *actions=self.actions;if(index.row<0||(NSUInteger)index.row>=actions.count)return;NSString *action=actions[index.row];
        if([action isEqual:@"folder"])[self.sync chooseFolderFrom:self];
        if([action isEqual:@"refresh"])[self.sync refresh];
        if([action isEqual:@"toggle"])[self.sync setSynchronizationEnabled:![self.sync.viewState[@"enabled"] boolValue]];
        if([action isEqual:@"cancel"])[self.sync cancelPendingSelection];
        if([action isEqual:@"backup"]) {
            NSString *base=self.sync.viewState[@"base"];
            if(!base.length){showMessage(self,@"尚无完整的已保存进度，完成一次游戏内保存后再试。");return;}
            promptName(self,@"",^(NSString *name){[self.sync nameBackup:name version:nil replacing:nil];});
        }
        if([action isEqual:@"continue"]){[self close];[self.sync continueLocal];}
        return;
    }
    NSDictionary *r=[self recordForIndex:index];NSString *version=index.section==3?r[@"target"]:r[@"id"];
    NSString *message=self.sync.gameRunning?@"当前游玩不会被打断，所选进度将在下次启动游戏时载入；现有历史仍保留。":@"将使用这份完整进度继续，其他版本仍保留。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:index.section==3?r[@"name"]:versionTitle(r) message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:self.sync.gameRunning?@"安排下次启动载入":@"使用此进度" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self.sync selectVersion:version restore:index.section!=1];}]];
    [alert addAction:[UIAlertAction actionWithTitle:index.section==3?@"修改备份名称":@"创建命名备份" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;promptName(self,index.section==3?r[@"name"]:@"",^(NSString *name){[self.sync nameBackup:name version:version replacing:index.section==3?r[@"id"]:nil];});
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
@interface TOTKProgressFolderDelegate : NSObject<UIDocumentPickerDelegate>
@property(strong) TOTKProgressSync *sync;
@property(weak) UIViewController *host;
@end
static TOTKProgressFolderDelegate *folderDelegate;
@implementation TOTKProgressFolderDelegate
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {(void)controller;folderDelegate=nil;}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSError *error=nil;if(urls.firstObject)[self.sync useFolder:urls.firstObject error:&error];
    UIViewController *host=self.host;NSString *message=TOTKProgressErrorMessage(error);
    [controller dismissViewControllerAnimated:YES completion:^{if(message)showMessage(host,message);}];folderDelegate=nil;
}
@end
id totk_progress_make_manager(TOTKProgressSync *sync,void (^enterGame)(void)) {
    TOTKProgressManager *manager=[[TOTKProgressManager alloc] initWithStyle:UITableViewStyleInsetGrouped];manager.sync=sync;
    manager.enterGame=enterGame;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:manager];navigation.modalPresentationStyle=UIModalPresentationFormSheet;
    return navigation;
}
void totk_progress_show_manager(TOTKProgressSync *sync,id host) {
    UIViewController *top=topController(host);if([top isKindOfClass:TOTKProgressManager.class])return;
    UINavigationController *navigation=totk_progress_make_manager(sync,nil);
    [top presentViewController:navigation animated:YES completion:nil];
}
void totk_progress_choose_folder(TOTKProgressSync *sync,id host) {
    if(folderDelegate)return;
    folderDelegate=[TOTKProgressFolderDelegate new];folderDelegate.sync=sync;folderDelegate.host=topController(host);
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];picker.delegate=folderDelegate;picker.allowsMultipleSelection=NO;
    [folderDelegate.host presentViewController:picker animated:YES completion:nil];
}
void totk_progress_offer_wait(TOTKProgressSync *sync,id host) {
    UIViewController *top=topController(host);if([top isKindOfClass:TOTKProgressManager.class]||[top isKindOfClass:UIAlertController.class])return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"正在接续游戏进度" message:sync.viewState[@"status"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续等待" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[sync refresh];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"使用本机进度继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[sync continueLocal];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看进度" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[sync showFrom:host];}]];
    [top presentViewController:alert animated:YES completion:nil];
}

#else
#import <AppKit/AppKit.h>
static NSWindow *hostWindow(id host) {return [host isKindOfClass:NSWindow.class]?host:NSApp.keyWindow;}
static void showMessage(id host,NSString *message) {
    NSWindow *window=hostWindow(host);if(!window||window.attachedSheet)return;
    NSAlert *alert=[NSAlert new];alert.messageText=@"游戏进度";alert.informativeText=message;[alert addButtonWithTitle:@"好"];[alert beginSheetModalForWindow:window completionHandler:nil];
}
static void promptName(id host,NSString *initial,void (^completion)(NSString *)) {
    NSAlert *alert=[NSAlert new];alert.messageText=@"命名备份";alert.informativeText=@"保留这次已完成的游戏存档。";
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,28)];field.stringValue=initial?:@"";field.placeholderString=@"例如：最终战之前";field.accessibilityLabel=@"备份名称";alert.accessoryView=field;
    [alert addButtonWithTitle:@"保留备份"];[alert addButtonWithTitle:@"取消"];
    NSWindow *window=hostWindow(host);if(!window)return;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn)completion(field.stringValue);}];
}
@interface TOTKProgressManager : NSWindowController<NSTableViewDataSource,NSTableViewDelegate>
@property(strong) TOTKProgressSync *sync;
@property(strong) NSTextField *status;
@property(strong) NSTableView *table;
@property(strong) NSArray<NSDictionary *> *rows;
@property(strong) NSButton *continueButton,*toggleButton,*cancelButton;
@end
@implementation TOTKProgressManager
- (instancetype)initWithSync:(TOTKProgressSync *)sync {
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,720,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if(!(self=[super initWithWindow:window]))return nil;
    self.sync=sync;window.title=@"游戏进度";window.releasedWhenClosed=NO;
    NSStackView *stack=[NSStackView new];stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.spacing=12;stack.alignment=NSLayoutAttributeLeading;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [window.contentView addSubview:stack];[NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:20],[stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],[stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:20],[stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-20]]];
    self.status=[NSTextField wrappingLabelWithString:@"正在准备进度列表…"];self.status.font=[NSFont systemFontOfSize:14];[stack addArrangedSubview:self.status];
    self.toggleButton=[NSButton buttonWithTitle:@"暂停云同步" target:self action:@selector(toggleSync)];
    self.continueButton=[NSButton buttonWithTitle:@"使用本机继续" target:self action:@selector(continueLocal)];
    self.cancelButton=[NSButton buttonWithTitle:@"取消下次载入安排" target:self action:@selector(cancelPending)];
    NSStackView *tools=[NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"选择 iCloud 文件夹" target:self action:@selector(choose)],[NSButton buttonWithTitle:@"检查同步" target:self action:@selector(check)],self.toggleButton]];[stack addArrangedSubview:tools];
    NSStackView *local=[NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"命名当前存档" target:self action:@selector(nameCurrent)],self.continueButton,self.cancelButton]];local.detachesHiddenViews=YES;[stack addArrangedSubview:local];
    NSScrollView *scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;
    self.table=[NSTableView new];self.table.rowHeight=46;self.table.delegate=self;self.table.dataSource=self;self.table.allowsMultipleSelection=NO;
    NSTableColumn *title=[[NSTableColumn alloc] initWithIdentifier:@"title"];title.title=@"进度与备份";title.width=410;[self.table addTableColumn:title];
    NSTableColumn *detail=[[NSTableColumn alloc] initWithIdentifier:@"detail"];detail.title=@"来源与版本";detail.width=240;[self.table addTableColumn:detail];
    scroll.documentView=self.table;[stack addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:260].active=YES;
    NSStackView *actions=[NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"选择为主进度" target:self action:@selector(select)],[NSButton buttonWithTitle:@"恢复所选历史" target:self action:@selector(restore)],[NSButton buttonWithTitle:@"修改备份名称" target:self action:@selector(rename)]]];[stack addArrangedSubview:actions];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshView) name:TOTKProgressDidChange object:sync];[self refreshView];return self;
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)refreshView {
    NSDictionary *state=self.sync.viewState;self.status.stringValue=statusText(state);
    self.toggleButton.title=[state[@"enabled"] boolValue]?@"暂停云同步":@"开启云同步";
    self.continueButton.hidden=![state[@"canContinueLocal"] boolValue];self.cancelButton.hidden=![state[@"pendingAction"] count];
    NSString *selectedID=self.selected[@"id"];
    NSMutableArray *rows=[NSMutableArray new];
    for(NSDictionary *r in state[@"versions"]) {
        NSMutableDictionary *row=[r mutableCopy];row[@"role"]=[state[@"heads"] count]>1&&[state[@"heads"] containsObject:r[@"id"]]?@"待选择":@"历史";
        if([r[@"id"] isEqual:state[@"base"]])row[@"role"]=@"当前";[rows addObject:row];
    }
    for(NSDictionary *r in state[@"backups"]) {NSMutableDictionary *row=[r mutableCopy];row[@"role"]=@"备份";[rows addObject:row];}
    self.rows=rows;[self.table reloadData];
    if(selectedID)for(NSUInteger i=0;i<rows.count;i++)if([rows[i][@"id"] isEqual:selectedID]){[self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];break;}
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {(void)tableView;return self.rows.count;}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index {
    (void)tableView;NSDictionary *r=self.rows[index];BOOL backup=[r[@"role"] isEqual:@"备份"];
    NSString *text=[column.identifier isEqual:@"title"]?[NSString stringWithFormat:@"%@ · %@",r[@"role"],backup?r[@"name"]:versionTitle(r)]:backup?@"固定保留":versionDetail(r);
    NSTextField *field=[NSTextField wrappingLabelWithString:text];field.font=[NSFont systemFontOfSize:13];return field;
}
- (NSDictionary *)selected {NSInteger row=self.table.selectedRow;return row>=0&&row<(NSInteger)self.rows.count?self.rows[row]:nil;}
- (void)choose {[self.sync chooseFolderFrom:self.window];}
- (void)check {[self.sync refresh];}
- (void)toggleSync {[self.sync setSynchronizationEnabled:![self.sync.viewState[@"enabled"] boolValue]];}
- (void)cancelPending {[self.sync cancelPendingSelection];}
- (void)continueLocal {[self close];[self.sync continueLocal];}
- (void)nameCurrent {
    NSString *base=self.sync.viewState[@"base"];if(!base.length){showMessage(self.window,@"尚无完整的已保存进度，完成一次游戏内保存后再试。");return;}
    promptName(self.window,@"",^(NSString *name){[self.sync nameBackup:name version:nil replacing:nil];});
}
- (void)rename {
    NSDictionary *r=self.selected;if(![r[@"role"] isEqual:@"备份"]){showMessage(self.window,@"请先选择一份命名备份。");return;}
    promptName(self.window,r[@"name"],^(NSString *name){[self.sync nameBackup:name version:r[@"target"] replacing:r[@"id"]];});
}
- (void)performRestore:(BOOL)restore {
    NSDictionary *r=self.selected;if(!r){showMessage(self.window,@"请先选择一份进度或备份。");return;}NSString *version=r[@"target"]?:r[@"id"];
    NSAlert *alert=[NSAlert new];alert.messageText=restore?@"恢复所选进度？":@"选择这份主进度？";
    alert.informativeText=self.sync.gameRunning?@"当前游玩不会被打断，将在下次启动时载入。其他版本仍保留。":@"将使用这份完整进度继续；其他版本仍保留。";
    [alert addButtonWithTitle:self.sync.gameRunning?@"安排下次载入":@"使用此进度"];[alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn)[self.sync selectVersion:version restore:restore];}];
}
- (void)select {[self performRestore:NO];}
- (void)restore {[self performRestore:YES];}
@end
static TOTKProgressManager *manager;
void totk_progress_show_manager(TOTKProgressSync *sync,id host) {
    (void)host;if(!manager)manager=[[TOTKProgressManager alloc] initWithSync:sync];[manager refreshView];[manager showWindow:nil];[manager.window makeKeyAndOrderFront:nil];
}
void totk_progress_choose_folder(TOTKProgressSync *sync,id host) {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=NO;panel.prompt=@"选择同步文件夹";
    void (^finish)(NSModalResponse)=^(NSModalResponse response){if(response==NSModalResponseOK){NSError *error=nil;[sync useFolder:panel.URL error:&error];if(error){NSAlert *alert=[NSAlert new];alert.messageText=TOTKProgressErrorMessage(error);[alert beginSheetModalForWindow:hostWindow(host) completionHandler:nil];}}};
    NSWindow *window=hostWindow(host);if(window)[panel beginSheetModalForWindow:window completionHandler:finish];else [panel beginWithCompletionHandler:finish];
}
void totk_progress_offer_wait(TOTKProgressSync *sync,id host) {
    NSWindow *window=hostWindow(host);if(!window||window.attachedSheet||manager.window.isVisible)return;
    NSAlert *alert=[NSAlert new];alert.messageText=@"正在接续游戏进度";alert.informativeText=sync.viewState[@"status"]?:@"正在检查…";
    [alert addButtonWithTitle:@"继续等待"];[alert addButtonWithTitle:@"使用本机进度继续"];[alert addButtonWithTitle:@"查看进度"];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response){if(response==NSAlertSecondButtonReturn)[sync continueLocal];else if(response==NSAlertThirdButtonReturn)[sync showFrom:host];else [sync refresh];}];
}
#endif
