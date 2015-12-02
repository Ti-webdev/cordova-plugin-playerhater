//
//  PRXPlayerPlugin.m
//  NYPRNative
//
//  Created by Bradford Kammin on 4/2/14.
//
//
#include <objc/runtime.h>
#import "CDVSound.h"
#import "PRXPlayerPlugin.h"

@implementation PRXPlayerPlugin
@synthesize mAudioHandler;
@synthesize mNetworkStatus;

#pragma mark Initialization

BOOL canBecomeFirstResponderImp(id self, SEL _cmd) {
    return YES;
}

void remoteControlReceivedWithEventImp(id self, SEL _cmd, UIEvent * event) {

    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInteger:event.subtype], @"buttonId",
                          nil];

    [[NSNotificationCenter defaultCenter]
     postNotificationName:@"RemoteControlEventNotification"
     object:nil
     userInfo:dict];
}

- (void)pluginInitialize
{
    // MainViewController is dynamically generated by 'cordova create', so...
    // dynamically add UIResponder methods to the MainViewController class to capture remote control events

    // what if another plugin does the same thing?

    class_addMethod([self.viewController class], @selector(canBecomeFirstResponder), (IMP) canBecomeFirstResponderImp, "c@:");
    class_addMethod([self.viewController class], @selector(remoteControlReceivedWithEvent:), (IMP) remoteControlReceivedWithEventImp, "v@:@");
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    [self.viewController becomeFirstResponder];

    // watch for local notification
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onLocalNotification:) name:CDVLocalNotification object:nil]; // if app is in foreground
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onUIApplicationDidFinishLaunchingNotification:) name:@"UIApplicationDidFinishLaunchingNotification" object:nil]; // if app is not in foreground or not running

    NSLog(@"PRXPlayer Plugin initialized");
}

- (void)init:(CDVInvokedUrlCommand*)command {

    NSLog (@"PRXPlayer Plugin init");

    CDVPluginResult* pluginResult = nil;

    if ( _audio!=nil) {

        NSLog(@"sending wakeup audio to js");

        NSDictionary * o = @{ @"type" : @"current",
                              @"audio" : _audio};

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];

        _audio = nil;

    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) _create {
    if(self->mAudioHandler==nil){
        NSLog (@"PRXPlayer Plugin creating handler.");

        if(self->mNetworkStatus==nil){
            CDVReachability * reach = [CDVReachability reachabilityForInternetConnection];
            [reach startNotifier];
            [self setNetworkStatus:reach];
        }

        self->mAudioHandler=[[AudioStreamHandler alloc]initWithCDVReachability:mNetworkStatus];

        [[NSNotificationCenter defaultCenter]   addObserver:self selector:@selector(_onAudioStreamUpdate:) name:@"AudioStreamUpdateNotification" object:nil];
        [[NSNotificationCenter defaultCenter]   addObserver:self selector:@selector(_onAudioProgressUpdate:) name:@"AudioProgressNotification" object:nil];
        [[NSNotificationCenter defaultCenter]   addObserver:self selector:@selector(_onAudioSkipPrevious:) name:@"AudioSkipPreviousNotification" object:nil];
        [[NSNotificationCenter defaultCenter]   addObserver:self selector:@selector(_onAudioSkipNext:) name:@"AudioSkipNextNotification" object:nil];
    }
}

#pragma mark Cleanup

-(void) _teardown
{
    if (self->mAudioHandler) {
        [self->mAudioHandler stopPlaying];
        self->mAudioHandler = nil;
    }

    if(self->mNetworkStatus){
        [self->mNetworkStatus stopNotifier];
        self->mNetworkStatus=nil;
    }
}

- (void)dispose {
    NSLog(@"PRXPlayer Plugin disposing");

    [self _teardown];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AudioStreamUpdateNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AudioProgressNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AudioSkipPreviousNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AudioSkipNextNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CDVLocalNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationDidFinishLaunchingNotification" object:nil];

    if ([[UIApplication sharedApplication] respondsToSelector:@selector(endReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    }

    [super dispose];
}

#pragma mark Plugin handler

-(void)_sendPluginResult:(CDVPluginResult*)result callbackId:(NSString*)callbackId{
    if(callbackId!=nil){
        _callbackId=callbackId;
    }

    if (_callbackId!=nil){
        [result setKeepCallbackAsBool:YES]; // keep for later callbacks
        [self.commandDelegate sendPluginResult:result callbackId:_callbackId];
    }
}

#pragma mark Audio playback commands

- (void)playstream:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult=nil;
    NSDictionary  * params = [command.arguments  objectAtIndex:0];
    NSString* url = [params objectForKey:@"ios"];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];

    if ( url && url != (id)[NSNull null] ) {
        [self _playstream:url info:info];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
       NSLog (@"PRXPlayer Plugin invalid stream (%@)", url);
       pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid stream url"];
    }

    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)_playstream:(NSString*)url info:(NSDictionary*)info {
    NSLog (@"PRXPlayer Plugin starting stream (%@)", url);
    [self _create];
    [self->mAudioHandler startPlayingStream:url];
    [self setaudioinfoInternal:info];
}

- (void)playfile:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSString* fullFilename = [command.arguments objectAtIndex:0];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    NSInteger position = 0;
    if ( command.arguments.count > 2 && [command.arguments objectAtIndex:2] != (id)[NSNull null] ) {
        position = [[command.arguments objectAtIndex:2] integerValue];
    }

    if ( fullFilename && fullFilename != (id)[NSNull null] ) {

        // get the filename at the end of the file
        NSString *file = [[[NSURL URLWithString:fullFilename]  lastPathComponent] lowercaseString];
        NSString* path = [self _getAudioDirectory];
        NSString* fullPathAndFile=[NSString stringWithFormat:@"%@%@",path, file];

        NSURL *fullPathURL = [NSURL URLWithString:fullFilename];
        NSString *fullPathString = [fullPathURL path];

        if([[NSFileManager defaultManager] fileExistsAtPath:fullPathAndFile]){
            NSLog (@"PRXPlayer Plugin playing local file (%@)", fullPathAndFile);
            [self _create];
            [self->mAudioHandler startPlayingLocalFile:fullPathAndFile position:position];
            [self setaudioinfoInternal:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else if([[NSFileManager defaultManager] fileExistsAtPath:fullPathString]) {
            NSLog (@"PRXPlayer Plugin playing local file (%@)", fullPathString);
            [self _create];
            [self->mAudioHandler startPlayingLocalFile:fullPathString position:position];
            [self setaudioinfoInternal:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            [self playremotefile:command];
        }

    }else {
        NSLog (@"PRXPlayer Plugin invalid file (%@)", fullFilename);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid file url"];
    }

    if (pluginResult!=nil) {
        [self _sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void)pause:(CDVInvokedUrlCommand*)command
{

    NSLog (@"PRXPlayer Plugin pausing playback");
    [self _create];
    [self->mAudioHandler pausePlaying];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)playremotefile:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSString* url = [command.arguments objectAtIndex:0];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    NSInteger position = 0;
    if (command.arguments.count>2 && [command.arguments objectAtIndex:2] != (id)[NSNull null]) {
        position = [[command.arguments objectAtIndex:2] integerValue];
    }

    if ( url && url != (id)[NSNull null] ) {
        NSLog (@"PRXPlayer Plugin playing remote file (%@)", url);
        [self _create];
        [self->mAudioHandler startPlayingRemoteFile:url position:position];
        [self setaudioinfoInternal:info];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        NSLog (@"PRXPlayer Plugin invalid remote file (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid remote file url"];
    }

    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seek:(CDVInvokedUrlCommand*)command
{
    NSInteger interval = [[command.arguments objectAtIndex:0] integerValue];

    NSLog (@"PRXPlayer Plugin seeking to interval (%d)", interval );
    [self _create];
    [self->mAudioHandler seekInterval:interval];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seekto:(CDVInvokedUrlCommand*)command
{
    NSInteger position = [[command.arguments objectAtIndex:0] integerValue];

    NSLog (@"PRXPLayer seeking to position (%d)", position );
    [self _create];
    [self->mAudioHandler seekTo:position];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand*)command
{
    NSLog (@"PRXPlayer Plugin stopping playback.");
    [self _create];
    [self->mAudioHandler stopPlaying];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)setaudioinfo:(CDVInvokedUrlCommand*)command{
    NSDictionary  * info = [command.arguments  objectAtIndex:0];
    [self setaudioinfoInternal:info];
}

- (void)setaudioinfoInternal:(NSDictionary*) info{

    NSString * title = nil;
    NSString * artist = nil;
    NSString * url = nil;

    title = [info objectForKey:@"title"];
    artist = [info objectForKey:@"artist"];

    NSDictionary * artwork = [info objectForKey:@"image"];

    if (artwork && artwork != (id)[NSNull null]){
        url = [artwork objectForKey:@"url"];
    }

    [self->mAudioHandler setAudioInfo:title artist:artist artwork:url];
}

#pragma mark Audio playback helper functions

- (void)setNetworkStatus:(CDVReachability*)reachability
{
    mNetworkStatus=reachability;
}

- (void)getaudiostate:(CDVInvokedUrlCommand*)command
{
    NSLog (@"PRXPlayer Plugin getting audio state");

    [self _create];
    [self->mAudioHandler getAudioState];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString*)_getAudioDirectory{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/Audio/",documentsDirectory];
    return path;
}

#pragma mark Audio playback event handlers

- (void) _onAudioStreamUpdate:(NSNotification *) notification
{
    if ([[notification name] isEqualToString:@"AudioStreamUpdateNotification"]){

        NSDictionary *dict = [notification userInfo];

        NSString * status = [dict objectForKey:(@"status")];
        NSString * description = [dict objectForKey:(@"description")];

        NSDictionary * o = @{ @"type" : @"state", @"state" : status, @"description" : description };
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
        [self _sendPluginResult:pluginResult callbackId:_callbackId];

        if([status intValue]==MEDIA_STOPPED){

            NSDictionary *dict2 = [NSDictionary dictionaryWithObjectsAndKeys:
                                   0, @"progress",
                                   0, @"duration"
                                   , nil];

            [[NSNotificationCenter defaultCenter]
             postNotificationName:@"AudioProgressNotification"
             object:self
             userInfo:dict2];

        } else if ([status intValue]==MEDIA_RUNNING){
            // todo - update lock screen...
        }
    }
}

- (void) _onAudioProgressUpdate:(NSNotification *) notification
{
    if ([[notification name] isEqualToString:@"AudioProgressNotification"]){

        NSDictionary *dict = [notification userInfo];

        int progress = [[dict  objectForKey:(@"progress")] integerValue];
        int duration = [[dict  objectForKey:(@"duration")] integerValue];
        int available = [[dict  objectForKey:(@"available")] integerValue];

        NSDictionary * o = @{ @"type" : @"progress",
                              @"progress" : [NSNumber numberWithInt:progress] ,
                              @"duration" : [NSNumber numberWithInt:duration],
                              @"available" : [NSNumber numberWithInt:available]};

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
        [self _sendPluginResult:pluginResult callbackId:_callbackId];
    }
}

- (void) _onAudioSkipNext:(NSNotification *) notification
{
    NSDictionary * o = @{ @"type" : @"next" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
}

- (void) _onAudioSkipPrevious:(NSNotification *) notification
{
    NSDictionary * o = @{ @"type" : @"previous" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
}


#pragma mark Wakeup handlers

- (void)_onLocalNotification:(NSNotification *)notification
{
    NSLog(@"PRXPlayer Plugin received local notification while app is running");

    UILocalNotification* localNotification = [notification object];

    [self _playStreamFromLocalNotification:localNotification];
}


-(void)_onUIApplicationDidFinishLaunchingNotification:(NSNotification*)notification {
    NSLog(@"PRXPlayer Plugin received local notification after launch invoked by clicking on notification");

    NSDictionary *userInfo = [notification userInfo] ;
    UILocalNotification *localNotification = [userInfo objectForKey: @"UIApplicationLaunchOptionsLocalNotificationKey"];
    if (localNotification) {
        [self _playStreamFromLocalNotification:localNotification];
    }
}

-(void)_playStreamFromLocalNotification:(UILocalNotification*)localNotification {
    NSString * notificationType = [[localNotification userInfo] objectForKey:@"type"];

    if ( notificationType!=nil && [notificationType isEqualToString:@"wakeup"]) {
        NSLog(@"wakeup detected!");

        NSString * s = [[localNotification userInfo] objectForKey:@"extra"];
        NSError *error;
        NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *extra = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

        if (extra!=nil){
            NSDictionary  * streams = [extra objectForKey:@"streams"];
            NSDictionary  * info = [extra objectForKey:@"info"];
            NSDictionary  * audio = [extra objectForKey:@"audio"];
            NSString* url = nil;

            if (streams) {
                url=[streams objectForKey:@"ios"];
                if (url!=nil) {
                    [self _playstream:url info:info];

                    if (_callbackId!=nil && audio!=nil) {
                        NSDictionary * o = @{ @"type" : @"current",
                                              @"audio" : audio};

                        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
                        [self _sendPluginResult:pluginResult callbackId:_callbackId];

                        _audio = nil;
                    } else {
                        _audio = audio; // send this when callback is available
                    }
                }
            }
        }
    }
}

@end
