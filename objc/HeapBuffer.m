//
//  HeapBuffer.m
//  libpd
//
//  Created by Bleass on 13/07/2017.
//
//

#import "HeapBuffer.h"

@implementation HeapBuffer

- (id)initWithMaxSize:(size_t)maxSize {
    self = [super init];
    if (self) {
        self->maximumBufferSize = maxSize;
        self->heap = (Float32*)malloc(maxSize*sizeof(Float32));
        memset(self->heap, 0, maxSize);
        locator = 0;
        currentSize = 0;
    }
    return self;
}

- (void)push:(Float32*)buffer size:(size_t)size {
    memcpy(self->heap + currentSize, buffer, size*sizeof(Float32));
    currentSize = currentSize + size;
    
    assert(currentSize < maximumBufferSize);
    
}
- (void)pull:(Float32**)buffer size:(size_t)size {
    assert(size <= currentSize);
    
    memcpy(*buffer, self->heap, size*sizeof(Float32));
    currentSize = currentSize - size;
    
    if (currentSize != 0) {
        memcpy(self->heap, self->heap + size, currentSize*sizeof(Float32));
    }
}

- (size_t ) remainingTicks:(UInt32)numChannels {
    return floor(currentSize / (64.f * 2.f));
}

@end
