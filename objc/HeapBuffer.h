//
//  HeapBuffer.h
//  libpd
//
//  Created by Bleass on 13/07/2017.
//
//

#import <Foundation/Foundation.h>

@interface HeapBuffer : NSObject {
    size_t maximumBufferSize;
    Float32* heap;
    size_t locator;
    size_t currentSize;
}

- (id)initWithMaxSize:(size_t)maxSize;

- (void)push:(Float32*)buffer size:(size_t)size;
- (void)pull:(Float32**)buffer size:(size_t)size;

- (size_t ) remainingTicks:(UInt32)numChannels;

@end
