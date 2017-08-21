//
//  PdAudioUnit.m
//  libpd
//
//  Created on 29/09/11.
//
//  For information on usage and redistribution, and for a DISCLAIMER OF ALL
//  WARRANTIES, see the file, "LICENSE.txt," in this distribution.
//

#import "PdAudioUnit.h"
#import "PdBase.h"
#import "AudioHelpers.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import "HeapBuffer.h"

static const AudioUnitElement kInputElement = 1;
static const AudioUnitElement kOutputElement = 0;

@interface PdAudioUnit () {
@private
	BOOL inputEnabled_;
	BOOL initialized_;
	int blockSizeAsLog_;
    
    ExtAudioFileRef extAudioFileRef;
    unsigned long audioFileSize;
    NSString* path;
    
    AudioStreamBasicDescription outputFormat;
}

- (BOOL)initAudioUnitWithSampleRate:(Float64)sampleRate numberChannels:(int)numChannels inputEnabled:(BOOL)inputEnabled;
- (void)destroyAudioUnit;
- (AudioComponentDescription)ioDescription;
@end

@implementation PdAudioUnit

@synthesize audioUnit = audioUnit_;
@synthesize active = active_;
@synthesize delegate = delegate_;

#pragma mark - AURenderCallback

static OSStatus AudioRenderCallback(void *inRefCon,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    
    PdAudioUnit *pdAudioUnit = (PdAudioUnit *)inRefCon;
    
    Float32 *auBuffer = (Float32 *)ioData->mBuffers[0].mData;
    
    if (pdAudioUnit->inputEnabled_) {
        AudioUnitRender(pdAudioUnit->audioUnit_, ioActionFlags, inTimeStamp, kInputElement, inNumberFrames, ioData);
        
        [pdAudioUnit sendVuValue:ioData withSize:inNumberFrames];
        if (pdAudioUnit->isRecording_) {
            [pdAudioUnit writeData:ioData withSize:inNumberFrames];
        }
    }
    
    float ticksOutput = ceil((inNumberFrames / 64.f)) - [pdAudioUnit->heapBufferOutput remainingTicks:2];
    
    [PdBase processFloatWithInputBuffer:pdAudioUnit->inputBuffer outputBuffer:pdAudioUnit->outputBuffer ticks:ticksOutput];
    
    [pdAudioUnit->heapBufferOutput push:pdAudioUnit->outputBuffer size:ticksOutput*64*2];
    
    [pdAudioUnit->heapBufferOutput pull:&(auBuffer) size:inNumberFrames*2];
    
    return noErr;
}

-(void)writeData:(AudioBufferList *)ioData withSize:(UInt32)inNumberFrames {
    
    OSStatus err = ExtAudioFileWriteAsync(extAudioFileRef,
                                          inNumberFrames,
                                          ioData);
    audioFileSize += inNumberFrames;
    
    Float32 audioFileSizeFloat = (Float32)audioFileSize;
    
    [delegate_ recordingProgress:(audioFileSizeFloat/ (44100.f*10.f))];
    
    if (audioFileSize > 44100*10) {
        [self closeRecording];
    }
}


-(void)sendVuValue:(AudioBufferList *)ioData withSize:(UInt32)inNumberFrames {
    
    Float32* dataBuf = (Float32 *)ioData->mBuffers[0].mData;
    
    Float32 fMag = 0;
    vDSP_maxmgv(dataBuf, 1, &fMag, inNumberFrames);
    
    [delegate_ receiveVuValue:fMag];
}

-(void)closeRecording {
    isRecording_ = NO;
    
    if (extAudioFileRef) {
        OSStatus result = ExtAudioFileDispose(extAudioFileRef);
        extAudioFileRef = NULL;
    }
    [delegate_ didCloseRecording];
}

-(BOOL)enableRecordingToPath:(NSString*)outputPath {
    
    audioFileSize = 0;
    
    outputFormat = [self ASBDForSampleRate:44100 numberChannels:2];
    NSURL* outputFileUrl = [NSURL fileURLWithPath:outputPath];
    path = outputPath;
    
    AudioStreamBasicDescription temp = {0};
    temp.mBytesPerFrame = 4;
    temp.mBytesPerPacket = 4;
    temp.mChannelsPerFrame = 2;
    temp.mBitsPerChannel = 16;
    temp.mFramesPerPacket = 1;
    temp.mFormatFlags = kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
    temp.mFormatID = kAudioFormatLinearPCM;
    temp.mSampleRate = 44100;
    
    UInt32 size = sizeof(temp);
    OSStatus err = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &temp);
    
    err = ExtAudioFileCreateWithURL((__bridge CFURLRef)outputFileUrl,
                                    kAudioFileWAVEType,
                                    &temp,
                                    NULL,
                                    kAudioFileFlags_EraseFile,
                                    &extAudioFileRef);
    
    
    err = ExtAudioFileSetProperty(extAudioFileRef,
                                  kExtAudioFileProperty_ClientDataFormat,
                                  sizeof(AudioStreamBasicDescription),
                                  &outputFormat);
    
    err = ExtAudioFileWriteAsync(extAudioFileRef, 0, NULL);
    
    isRecording_ = YES;
    
    return YES;
}

-(NSString*)pathToRecording {
    return path;
}

#pragma mark - Init / Dealloc

#define MAX_BUFFER_SIZE 8192

- (id)init {
	self = [super init];
	if (self) {
		initialized_ = NO;
		active_ = NO;
        isRecording_ = NO;
		blockSizeAsLog_ = log2int([PdBase getBlockSize]);
        _debugString = 0;
        
        heapBufferOutput = [[HeapBuffer alloc] initWithMaxSize:MAX_BUFFER_SIZE];
        
        inputBuffer = (Float32*)malloc(sizeof(Float32)*MAX_BUFFER_SIZE);
        memset(inputBuffer, 0, MAX_BUFFER_SIZE);
        outputBuffer = (Float32*)malloc(sizeof(Float32)*MAX_BUFFER_SIZE);
        memset(outputBuffer, 0, MAX_BUFFER_SIZE);
        vuMeterBuffer = (Float32*)malloc(sizeof(Float32)*MAX_BUFFER_SIZE);
        memset(vuMeterBuffer, 0, MAX_BUFFER_SIZE);
        
	}
	return self;
}

- (void)dealloc {
	[self destroyAudioUnit];
	[super dealloc];
}

#pragma mark - Public Methods

- (void)setActive:(BOOL)active {
	if (!initialized_) {
		return;
	}
	if (active == active_) {
		return;
	}
	if (active) {
		AU_RETURN_IF_ERROR(AudioOutputUnitStart(audioUnit_));
	} else {
		AU_RETURN_IF_ERROR(AudioOutputUnitStop(audioUnit_));
	}
	active_ = active;
}

- (int)configureWithSampleRate:(Float64)sampleRate numberChannels:(int)numChannels inputEnabled:(BOOL)inputEnabled {
	Boolean wasActive = self.isActive;
	inputEnabled_ = inputEnabled;
	if (![self initAudioUnitWithSampleRate:sampleRate numberChannels:numChannels inputEnabled:inputEnabled_]) {
		return -1;
	}
	[PdBase openAudioWithSampleRate:sampleRate inputChannels:(inputEnabled_ ? numChannels : 0) outputChannels:numChannels];
	[PdBase computeAudio:YES];
	self.active = wasActive;
	return 0;
}

- (void)print {
	if (!initialized_) {
		AU_LOG(@"Audio Unit not initialized");
		return;
	}
	
	UInt32 sizeASBD = sizeof(AudioStreamBasicDescription);
	
	if (inputEnabled_) {
		AudioStreamBasicDescription inputStreamDescription;
		memset (&inputStreamDescription, 0, sizeof(inputStreamDescription));
		AU_RETURN_IF_ERROR(AudioUnitGetProperty(audioUnit_,
                           kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output,
                           kInputElement,
                           &inputStreamDescription,
                           &sizeASBD));
		AU_LOG(@"input ASBD:");
		AU_LOG(@"  mSampleRate: %.0fHz", inputStreamDescription.mSampleRate);
		AU_LOG(@"  mChannelsPerFrame: %u", (unsigned int)inputStreamDescription.mChannelsPerFrame);
		AU_LOGV(@"  mFormatID: %lu", inputStreamDescription.mFormatID);
		AU_LOGV(@"  mFormatFlags: %lu", inputStreamDescription.mFormatFlags);
		AU_LOGV(@"  mBytesPerPacket: %lu", inputStreamDescription.mBytesPerPacket);
		AU_LOGV(@"  mFramesPerPacket: %lu", inputStreamDescription.mFramesPerPacket);
		AU_LOGV(@"  mBytesPerFrame: %lu", inputStreamDescription.mBytesPerFrame);
		AU_LOGV(@"  mBitsPerChannel: %lu", inputStreamDescription.mBitsPerChannel);
	} else {
		AU_LOG(@"no input ASBD");
	}
	
	AudioStreamBasicDescription outputStreamDescription;
	memset(&outputStreamDescription, 0, sizeASBD);
	AU_RETURN_IF_ERROR(AudioUnitGetProperty(audioUnit_,
                       kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Input,
                       kOutputElement,
                       &outputStreamDescription,
                       &sizeASBD));
	AU_LOG(@"output ASBD:");
	AU_LOG(@"  mSampleRate: %.0fHz", outputStreamDescription.mSampleRate);
	AU_LOG(@"  mChannelsPerFrame: %u", (unsigned int)outputStreamDescription.mChannelsPerFrame);
	AU_LOGV(@"  mFormatID: %lu", outputStreamDescription.mFormatID);
	AU_LOGV(@"  mFormatFlags: %lu", outputStreamDescription.mFormatFlags);
	AU_LOGV(@"  mBytesPerPacket: %lu", outputStreamDescription.mBytesPerPacket);
	AU_LOGV(@"  mFramesPerPacket: %lu", outputStreamDescription.mFramesPerPacket);
	AU_LOGV(@"  mBytesPerFrame: %lu", outputStreamDescription.mBytesPerFrame);
	AU_LOGV(@"  mBitsPerChannel: %lu", outputStreamDescription.mBitsPerChannel);
}

// sets the format to 32 bit, floating point, linear PCM, interleaved
- (AudioStreamBasicDescription)ASBDForSampleRate:(Float64)sampleRate numberChannels:(UInt32)numberChannels {
	const int kFloatSize = 4;
	const int kBitSize = 8;
	
	AudioStreamBasicDescription description;
	memset(&description, 0, sizeof(description));
	
	description.mSampleRate = sampleRate;
	description.mFormatID = kAudioFormatLinearPCM;
	description.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	description.mBytesPerPacket = kFloatSize * numberChannels;
	description.mFramesPerPacket = 1;
	description.mBytesPerFrame = kFloatSize * numberChannels;
	description.mChannelsPerFrame = numberChannels;
	description.mBitsPerChannel = kFloatSize * kBitSize;
	
	return description;
}

- (AURenderCallback)renderCallback {
	return AudioRenderCallback;
}

#pragma mark - Private

- (void)destroyAudioUnit {
	if (!initialized_) {
		return;
	}
	self.active = NO;
	initialized_ = NO;
	AU_RETURN_IF_ERROR(AudioUnitUninitialize(audioUnit_));
	AU_RETURN_IF_ERROR(AudioComponentInstanceDispose(audioUnit_));
	AU_LOGV(@"destroyed audio unit");
}

- (BOOL)initAudioUnitWithSampleRate:(Float64)sampleRate numberChannels:(int)numChannels inputEnabled:(BOOL)inputEnabled {
	[self destroyAudioUnit];
	AudioComponentDescription ioDescription = [self ioDescription];
	AudioComponent audioComponent = AudioComponentFindNext(NULL, &ioDescription);
	AU_RETURN_FALSE_IF_ERROR(AudioComponentInstanceNew(audioComponent, &audioUnit_));
	
	AudioStreamBasicDescription streamDescription = [self ASBDForSampleRate:sampleRate numberChannels:numChannels];
	if (inputEnabled) {
		UInt32 enableInput = 1;
		AU_RETURN_FALSE_IF_ERROR(AudioUnitSetProperty(audioUnit_,
                                                      kAudioOutputUnitProperty_EnableIO,
                                                      kAudioUnitScope_Input,
                                                      kInputElement,
                                                      &enableInput,
                                                      sizeof(enableInput)));
		
		AU_RETURN_FALSE_IF_ERROR(AudioUnitSetProperty(audioUnit_,
                                                      kAudioUnitProperty_StreamFormat,
                                                      kAudioUnitScope_Output,  // Output scope because we're defining the output of the input element _to_ our render callback
                                                      kInputElement,
                                                      &streamDescription,
                                                      sizeof(streamDescription)));
	}
	
	AU_RETURN_FALSE_IF_ERROR(AudioUnitSetProperty(audioUnit_,
                                                  kAudioUnitProperty_StreamFormat,
                                                  kAudioUnitScope_Input,  // Input scope because we're defining the input of the output element _from_ our render callback.
                                                  kOutputElement,
                                                  &streamDescription,
                                                  sizeof(streamDescription)));
	
	AURenderCallbackStruct callbackStruct;
	callbackStruct.inputProc = self.renderCallback;
	callbackStruct.inputProcRefCon = self;
    
	AU_RETURN_FALSE_IF_ERROR(AudioUnitSetProperty(audioUnit_,
                                                  kAudioUnitProperty_SetRenderCallback,
                                                  kAudioUnitScope_Input,
                                                  kOutputElement,
                                                  &callbackStruct,
                                                  sizeof(callbackStruct)));
    
    //AudioUnitAddPropertyListener(audioUnit_, kAudioUnitProperty_MaximumFramesPerSlice, listener, self);
	
    //sAudioUnitAddPropertyListener(audioUnit_, kAudioUnitProperty_SampleRate, listener, self);
    
	AU_RETURN_FALSE_IF_ERROR(AudioUnitInitialize(audioUnit_));
	initialized_ = YES;
	AU_LOGV(@"initialized audio unit");
	return true;
}

- (AudioComponentDescription)ioDescription {
	AudioComponentDescription description;
	description.componentType = kAudioUnitType_Output;
	description.componentSubType = kAudioUnitSubType_RemoteIO;
	description.componentManufacturer = kAudioUnitManufacturer_Apple;
	description.componentFlags = 0;
	description.componentFlagsMask = 0;
	return description;
}

@end
