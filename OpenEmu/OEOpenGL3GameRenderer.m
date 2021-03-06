//
//  OEOpenGL2DGameRenderer.m
//  OpenEmu
//
//  Created by Alexander Strange on 10/18/15.
//
//

#import "OEOpenGL3GameRenderer.h"
#import <OpenGL/gl3.h>
#import <OpenGL/gl3ext.h>

@implementation OEOpenGL3GameRenderer
{
    // GL stuff
    CGLContextObj         _glContext;
    CGLPixelFormatObj     _glPixelFormat;
    GLuint                _ioSurfaceFBO;     // Framebuffer object which the ioSurfaceTexture is tied to
    GLuint                _depthStencilRB;   // FBO RenderBuffer Attachment for depth and stencil buffer
    GLuint                _ioSurfaceTexture; // texture wrapping the IOSurface, used as the render target. Uses the usual pixel format.

    // Double buffered FBO rendering (3D mode)
    BOOL                  _isDoubleBufferFBOMode;
    GLuint                _alternateFBO;     // 3D games may render into this FBO which is blit into the IOSurface. Used if game accidentally syncs surface.
    GLuint                _tempRB[2];        // Color and depth buffers backing alternate FBO.

    // Alternate-thread rendering (3D mode)
    CGLContextObj         _alternateContext; // Alternate thread's GL2 context
    dispatch_semaphore_t  _renderingThreadCanProceedSemaphore;
    dispatch_semaphore_t  _executeThreadCanProceedSemaphore;
}

@synthesize gameCore=_gameCore;
@synthesize ioSurface=_ioSurface;
@synthesize surfaceSize=_surfaceSize;

- (id)init
{
    self = [super init];
    // just be sane for now.
    _ioSurfaceFBO= 0;

    return self;
}

- (void)dealloc
{
    [self destroyGLResources];
}

- (void)updateRenderer
{
    [self destroyGLResources];
    [self setupVideo];
}

// Properties
- (BOOL)canChangeBufferSize
{
    // TODO: Test alternate threads - might need to call glViewport() again on that thread.
    // TODO: Implement for double buffered FBO - need to reallocate alternateFBO.

    return _alternateContext == NULL && !_isDoubleBufferFBOMode;
}

- (id)presentationFramebuffer
{
    GLuint fbo = _isDoubleBufferFBOMode ? _alternateFBO : _ioSurfaceFBO;

    return @(fbo);
}

- (void)setupVideo
{
    DLog(@"Setting up OpenGL3.x Core Profile renderer");

    [self setupGLContext];
    [self setupFramebuffer];
    if (_gameCore.needsDoubleBufferedFBO)
        [self setupDoubleBufferedFBO];
    if (_gameCore.hasAlternateRenderingThread)
        [self setupAlternateRenderingThread];
    [self clearFramebuffer];
    glFlushRenderAPPLE();
}

- (void)setupGLContext
{
    // init our context.
    static const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated,
        kCGLPFAAllowOfflineRenderers,
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFADepthSize, 24,
        0 };

    CGLError err = kCGLNoError;
    GLint numPixelFormats = 0;

    err = CGLChoosePixelFormat(attributes, &_glPixelFormat, &numPixelFormats);

    if(err != kCGLNoError)
    {
        NSLog(@"Error choosing pixel format %s", CGLErrorString(err));
        [[NSApplication sharedApplication] terminate:nil];
    }
    CGLRetainPixelFormat(_glPixelFormat);

    err = CGLCreateContext(_glPixelFormat, NULL, &_glContext);
    if(err != kCGLNoError)
    {
        NSLog(@"Error creating context %s", CGLErrorString(err));
        [[NSApplication sharedApplication] terminate:nil];
    }
    CGLRetainContext(_glContext);
    CGLEnable(_glContext, kCGLCECrashOnRemovedFunctions);

    CGLSetCurrentContext(_glContext);
}

- (void)setupFramebuffer
{
    GLenum status;

    // Wrap the IOSurface in a texture
    glGenTextures(1, &_ioSurfaceTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE, _ioSurfaceTexture);

    CGLError err = CGLTexImageIOSurface2D(_glContext, GL_TEXTURE_RECTANGLE, GL_RGBA8,
                                          (GLsizei)_surfaceSize.width, (GLsizei)_surfaceSize.height,
                                          GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, self.ioSurface, 0);
    if(err != kCGLNoError) {
        NSLog(@"Error creating IOSurface texture: %s & %x", CGLErrorString(err), glGetError());
    }

    // Unbind
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);

    // Wrap the texture in an FBO (wow, so indirect)
    glGenFramebuffers(1, &_ioSurfaceFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, _ioSurfaceFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, _ioSurfaceTexture, 0);
    status = glGetError();
    if(status != 0)
    {
        NSLog(@"setup: create ioSurface FBO 1, OpenGL error %04X", status);
    }

    // Complete the FBO
    glGenRenderbuffers(1, &_depthStencilRB);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthStencilRB);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)_surfaceSize.width, (GLsizei)_surfaceSize.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthStencilRB);
    status = glGetError();
    if(status != 0)
    {
        NSLog(@"setup: create ioSurface FBO 2, OpenGL error %04X", status);
    }

    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if(status != GL_FRAMEBUFFER_COMPLETE)
    {
        NSLog(@"Cannot create FBO, OpenGL error %04X", status);
    }

    glViewport(0, 0, _surfaceSize.width, _surfaceSize.height);
}

- (void)setupAlternateRenderingThread
{
    if(_alternateContext == NULL)
        CGLCreateContext(_glPixelFormat, _glContext, &_alternateContext);

    _renderingThreadCanProceedSemaphore = dispatch_semaphore_create(0);
    _executeThreadCanProceedSemaphore   = dispatch_semaphore_create(0);
}

- (void)setupDoubleBufferedFBO
{
    [self clearFramebuffer];
    glGenFramebuffers(1, &_alternateFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, _alternateFBO);

    glGenRenderbuffers(2, _tempRB);
    glBindRenderbuffer(GL_RENDERBUFFER, _tempRB[0]);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGB8, (GLsizei)_surfaceSize.width, (GLsizei)_surfaceSize.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _tempRB[0]);

    glBindRenderbuffer(GL_RENDERBUFFER, _tempRB[1]);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH32F_STENCIL8, (GLsizei)_surfaceSize.width, (GLsizei)_surfaceSize.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _tempRB[1]);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if(status != GL_FRAMEBUFFER_COMPLETE)
    {
        NSLog(@"Cannot create temp FBO");
        NSLog(@"OpenGL error %04X", status);

        glDeleteFramebuffers(1, &_alternateFBO);
    }

    glClear(GL_COLOR_BUFFER_BIT);

    _isDoubleBufferFBOMode = YES;
}

- (void)clearFramebuffer
{
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

- (void)destroyGLResources
{
    if (_glContext) {
        if (_alternateContext)
            CGLReleaseContext(_alternateContext);
        CGLReleasePixelFormat(_glPixelFormat);
        CGLReleaseContext(_glContext);

        _alternateContext = nil;
        _glContext = nil;
        _glPixelFormat = nil;
    }
}

// Execution

- (void)bindFBO:(GLuint)fbo
{
    // Bind our FBO / and thus our IOSurface
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    // Assume FBOs JUST WORK, because we checked on startExecution
    GLenum status = glGetError();
    if(status)
    {
        NSLog(@"draw: bind FBO: OpenGL error %04X", status);
    }

    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if(status != GL_FRAMEBUFFER_COMPLETE)
    {
        NSLog(@"OpenGL error %04X in draw, check FBO", status);
    }
}

- (void)copyAlternateFBO
{
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _alternateFBO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _ioSurfaceFBO);

    glBlitFramebuffer(0, 0, _surfaceSize.width, _surfaceSize.height,
                      0, 0, _surfaceSize.width, _surfaceSize.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, _alternateFBO);
}

- (void)willExecuteFrame
{
    if (_alternateContext)
        return; // should avoid work in this thread

    CGLSetCurrentContext(_glContext);

    // Bind the FBO just in case that works.
    // Note that most GL3 cores will use their own FBOs and overwrite ours.
    // Their graphics plugins will need to be adapted to write to ours - see -presentationFramebuffer.
    [self bindFBO:_isDoubleBufferFBOMode ? _alternateFBO : _ioSurfaceFBO];
}

- (void)didExecuteFrame
{
    if (_alternateContext) return;

    if (_isDoubleBufferFBOMode)
        [self copyAlternateFBO];

    // Update the IOSurface.
    glFlushRenderAPPLE();
}

- (void)willRenderFrameOnAlternateThread
{
    CGLSetCurrentContext(_alternateContext);

    [self bindFBO:_isDoubleBufferFBOMode ? _alternateFBO : _ioSurfaceFBO];
}

- (void)didRenderFrameOnAlternateThread
{
    if (_isDoubleBufferFBOMode)
        [self copyAlternateFBO];

    // Update the IOSurface.
    glFlushRenderAPPLE();
}

@end
