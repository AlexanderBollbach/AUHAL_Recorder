
#import <AudioToolbox/AudioToolbox.h>
#include <ApplicationServices/ApplicationServices.h>

#include <pthread.h>
#include <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static void CheckError(OSStatus error, const char *operation);



typedef struct MyAUGraphPlayer
{
   AudioStreamBasicDescription streamFormat;
   
   AUGraph graph;
   AudioUnit inputUnit;
   AudioUnit outputUnit;

   
   AudioBufferList *inputBuffer;
   
   Float64 firstInputSampleTime;
   Float64 firstOutputSampleTime;
   Float64 inToOutSampleTimeOffset;
   
   
   dispatch_queue_t fileWritingQueue;
   
   ExtAudioFileRef					recordFile;
   SInt64 startingByte;
   
} MyAUGraphPlayer;

OSStatus InputRenderProc(void *inRefCon,
                         AudioUnitRenderActionFlags *ioActionFlags,
                         const AudioTimeStamp *inTimeStamp,
                         UInt32 inBusNumber,
                         UInt32 inNumberFrames,
                         AudioBufferList * ioData);
OSStatus GraphRenderProc(void *inRefCon,
                         AudioUnitRenderActionFlags *ioActionFlags,
                         const AudioTimeStamp *inTimeStamp,
                         UInt32 inBusNumber,
                         UInt32 inNumberFrames,
                         AudioBufferList * ioData);
void CreateInputUnit (MyAUGraphPlayer *player);
void CreateMyAUGraph(MyAUGraphPlayer *player);

#pragma mark - render proc -
OSStatus InputRenderProc(void *inRefCon,
                         AudioUnitRenderActionFlags *ioActionFlags,
                         const AudioTimeStamp *inTimeStamp,
                         UInt32 inBusNumber,
                         UInt32 inNumberFrames,
                         AudioBufferList * ioData)
{
   MyAUGraphPlayer *player = (MyAUGraphPlayer*) inRefCon;

   // rendering incoming mic samples to player->inputBuffer
   OSStatus inputProcErr = noErr;
   CheckError(inputProcErr = AudioUnitRender(player->inputUnit,
                                             ioActionFlags,
                                             inTimeStamp,
                                             inBusNumber,
                                             inNumberFrames,
                                             player->inputBuffer), "input render");
   
   printf("%i", inNumberFrames);
  // dispatch_async(player->fileWritingQueue, ^{
   CheckError(ExtAudioFileWriteAsync(player->recordFile, 4096, player->inputBuffer), "extaudioWiteinInputCallback");
  // });

   return inputProcErr;
}





void CreateInputUnit (MyAUGraphPlayer *player) {
   
   // generate description that will match audio HAL
   AudioComponentDescription inputcd = {0};
   inputcd.componentType = kAudioUnitType_Output;
   inputcd.componentSubType = kAudioUnitSubType_HALOutput;
   inputcd.componentManufacturer = kAudioUnitManufacturer_Apple;
   
   AudioComponent comp = AudioComponentFindNext(NULL, &inputcd);
   if (comp == NULL) {
      printf ("can't get output unit");
      exit (-1);
   }
   
   CheckError(AudioComponentInstanceNew(comp, &player->inputUnit),
              "Couldn't open component for inputUnit");
   
   // enable/io
   UInt32 disableFlag = 0;
   UInt32 enableFlag = 1;
   AudioUnitScope outputBus = 0;
   AudioUnitScope inputBus = 1;
   CheckError (AudioUnitSetProperty(player->inputUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Input,
                                    inputBus,
                                    &enableFlag,
                                    sizeof(enableFlag)), "Couldn't enable input on I/O unit");
   
   CheckError (AudioUnitSetProperty(player->inputUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output,
                                    outputBus,
                                    &disableFlag,	// well crap, have to disable
                                    sizeof(enableFlag)), "Couldn't disable output on I/O unit");
   
   AudioDeviceID defaultDevice = kAudioObjectUnknown;
   UInt32 propertySize = sizeof (defaultDevice);

   AudioObjectPropertyAddress defaultDeviceProperty;
   defaultDeviceProperty.mSelector = kAudioHardwarePropertyDefaultInputDevice;
   defaultDeviceProperty.mScope = kAudioObjectPropertyScopeGlobal;
   defaultDeviceProperty.mElement = kAudioObjectPropertyElementMaster;
   
   CheckError (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                          &defaultDeviceProperty,
                                          0,
                                          NULL,
                                          &propertySize,
                                          &defaultDevice), "Couldn't get default input device");
   
   UInt32 bufferProp = 4096;
   
   AudioObjectPropertyAddress defaultDeviceProperty2;
   defaultDeviceProperty2.mSelector = kAudioDevicePropertyBufferFrameSize;
   defaultDeviceProperty2.mScope = kAudioObjectPropertyScopeGlobal;
   defaultDeviceProperty2.mElement = kAudioObjectPropertyElementMaster;
   
   AudioObjectSetPropertyData(defaultDevice,
                              &defaultDeviceProperty2,
                              NULL,
                              NULL,
                              sizeof(bufferProp),
                              &bufferProp);

   CheckError(AudioUnitSetProperty(player->inputUnit,
                                   kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global,
                                   outputBus,
                                   &defaultDevice,
                                   sizeof(defaultDevice)), "Couldn't set default device on I/O unit");
   
   
   
   
   
   // use the stream format coming out of the AUHAL (should be de-interleaved)
   propertySize = sizeof (AudioStreamBasicDescription);
   CheckError(AudioUnitGetProperty(player->inputUnit,
                                   kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output,
                                   inputBus,
                                   &player->streamFormat,
                                   &propertySize), "Couldn't get ASBD from input unit");
   
   // 9/6/10 - check the input device's stream format
   AudioStreamBasicDescription deviceFormat;
   CheckError(AudioUnitGetProperty(player->inputUnit,
                                   kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input,
                                   inputBus,
                                   &deviceFormat,
                                   &propertySize),  "Couldn't get ASBD from input unit");
   
   printf ("Device rate %f, graph rate %f\n", deviceFormat.mSampleRate, player->streamFormat.mSampleRate);
   player->streamFormat.mSampleRate = deviceFormat.mSampleRate;
   
   propertySize = sizeof (AudioStreamBasicDescription);
   CheckError(AudioUnitSetProperty(player->inputUnit,
                                   kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output,
                                   inputBus,
                                   &player->streamFormat,
                                   propertySize), "Couldn't set ASBD on input unit");
   
   UInt32 bufferSizeFrames = 0;
   propertySize = sizeof(UInt32);
   CheckError (AudioUnitGetProperty(player->inputUnit,
                                    kAudioDevicePropertyBufferFrameSize,
                                    kAudioUnitScope_Global,
                                    0,
                                    &bufferSizeFrames,
                                    &propertySize), "Couldn't get buffer frame size from input unit");
   UInt32 bufferSizeBytes = bufferSizeFrames * sizeof(Float32);
   
   
   if (player->streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
      
      int offset = offsetof(AudioBufferList, mBuffers[0]);
      int sizeOfAB = sizeof(AudioBuffer);
      int chNum = player->streamFormat.mChannelsPerFrame;
      
      int inputBufferSize = offset + sizeOfAB * chNum;
      
      //malloc buffer lists
      player->inputBuffer = (AudioBufferList *)malloc(inputBufferSize);
      player->inputBuffer->mNumberBuffers = chNum;
      
      for (UInt32 i = 0; i < chNum ; i++) {
         player->inputBuffer->mBuffers[i].mNumberChannels = 1;
         player->inputBuffer->mBuffers[i].mDataByteSize = bufferSizeBytes;
         player->inputBuffer->mBuffers[i].mData = malloc(bufferSizeBytes);
      }
   }
  
   
   // set render proc to supply samples from input unit
   AURenderCallbackStruct callbackStruct;
   callbackStruct.inputProc = InputRenderProc;
   callbackStruct.inputProcRefCon = player;
   
   CheckError(AudioUnitSetProperty(player->inputUnit,
                                   kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global,
                                   0,
                                   &callbackStruct,
                                   sizeof(callbackStruct)),
              "Couldn't set input callback");
   

   

   
}




int main(void) {
   
   MyAUGraphPlayer player = {0};
   player.startingByte = 0;
   memset (&player, 0, sizeof (player));
   
   CFURLRef myFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR("./test2.wav"), kCFURLPOSIXPathStyle, false);
   
   CreateInputUnit(&player); // create AUHAL
   
   printf("samplerate %f", player.streamFormat.mSampleRate);
   
   ExtAudioFileCreateWithURL(myFileURL,
                             kAudioFileWAVEType,
                             &player.streamFormat,
                             NULL,
                             kAudioFileFlags_EraseFile,
                             &player.recordFile);
   player.fileWritingQueue = dispatch_queue_create("myQueue", NULL);
   
 //  ExtAudioFileWriteAsync(player.recordFile, 0, NULL);
   
   CheckError(AudioUnitInitialize(player.inputUnit), "Couldn't initialize input unit");
   CheckError (AudioOutputUnitStart(player.inputUnit), "AudioOutputUnitStart failed"); // starts getting callbacks
   
   // and wait
   printf("Capturing, press <return> to stop:\n");
   getchar();
   
   
   // cleanup
   ExtAudioFileDispose(player.recordFile);
   AUGraphStop (player.graph);
   AUGraphUninitialize (player.graph);
   AUGraphClose(player.graph);
   
   dispatch_release(player.fileWritingQueue);
   
}




#pragma mark - utility functions -

// generic error handler - if err is nonzero, prints error message and exits program.
static void CheckError(OSStatus error, const char *operation)
{
   if (error == noErr) return;
   
   char str[20];
   // see if it appears to be a 4-char-code
   *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
   if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
      str[0] = str[5] = '\'';
      str[6] = '\0';
   } else
      // no, format it as an integer
      sprintf(str, "%d", (int)error);
   
   fprintf(stderr, "Error: %s (%s)\n", operation, str);
   
   exit(1);
}


