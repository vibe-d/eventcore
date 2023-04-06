module eventcore.internal.corefoundation;

version (OSX) enum isAppleOS = true;
else version (iOS) enum isAppleOS = true;
else version (TVOS) enum isAppleOS = true;
else version (WatchOS) enum isAppleOS = true;
else enum isAppleOS = false;

static if (isAppleOS):

nothrow extern(C):

static if (!is(CFTypeRef)) {
	alias CFTypeRef = const(void)*;
	alias CFTypeRef CFAllocatorRef;
	extern const CFAllocatorRef kCFAllocatorDefault;

	CFTypeRef CFRetain(CFTypeRef cf) @nogc;
	void CFRelease(CFTypeRef cf) @nogc;

	struct __CFString;
	alias CFStringRef = const(__CFString)*;

	alias Boolean = ubyte;
	alias UniChar = ushort;
	alias CFTypeID = size_t;
	alias CFIndex = sizediff_t;

	alias CFAllocatorRetainCallBack = const(void)* function(const void *info);
	alias CFAllocatorReleaseCallBack = void function(const void *info);
	alias CFAllocatorCopyDescriptionCallBack = CFStringRef function(const void *info);
}

static if (!is(CFArrayRef)) {
	struct __CFArray;
	alias CFArrayRef = const(__CFArray)*;

	alias CFArrayRetainCallBack = const(void)* function(CFAllocatorRef allocator, const(void)* value);
	alias CFArrayReleaseCallBack = void function(CFAllocatorRef allocator, const(void)* value);
	alias CFArrayCopyDescriptionCallBack = CFStringRef function(const(void)* value);
	alias CFArrayEqualCallBack = Boolean function(const(void)* value1, const(void)* value2);

	struct CFArrayCallBacks {
		CFIndex version_;
		CFArrayRetainCallBack retain;
		CFArrayReleaseCallBack release;
		CFArrayCopyDescriptionCallBack copyDescription;
		CFArrayEqualCallBack equal;
	}

	CFArrayRef CFArrayCreate(CFAllocatorRef allocator, const(void)** values, CFIndex numValues, const(CFArrayCallBacks)* callBacks);
}

static if (!is(CFStringEncoding)) {
	alias CFStringEncoding = uint;

	enum kCFStringEncodingInvalidId = 0xffffffffU;
	enum {
	    kCFStringEncodingMacRoman = 0,
	    kCFStringEncodingWindowsLatin1 = 0x0500,
	    kCFStringEncodingISOLatin1 = 0x0201,
	    kCFStringEncodingNextStepLatin = 0x0B01,
	    kCFStringEncodingASCII = 0x0600,
	    kCFStringEncodingUnicode = 0x0100,
	    kCFStringEncodingUTF8 = 0x08000100,
	    kCFStringEncodingNonLossyASCII = 0x0BFF,

	    kCFStringEncodingUTF16 = 0x0100,
	    kCFStringEncodingUTF16BE = 0x10000100,
	    kCFStringEncodingUTF16LE = 0x14000100,

	    kCFStringEncodingUTF32 = 0x0c000100,
	    kCFStringEncodingUTF32BE = 0x18000100,
	    kCFStringEncodingUTF32LE = 0x1c000100
	}

	CFStringRef CFStringCreateWithCString(CFAllocatorRef alloc, const(char)* cStr, CFStringEncoding encoding);
	CFStringRef CFStringCreateWithBytes(CFAllocatorRef alloc, const(ubyte)* bytes, CFIndex numBytes, CFStringEncoding encoding, Boolean isExternalRepresentation);
	CFStringRef CFStringCreateWithCharacters(CFAllocatorRef alloc, const(UniChar)* chars, CFIndex numChars);
}

static if (!is(CFRunLoopRef)) {
	alias CFRunLoopMode = CFStringRef;
	struct __CFRunLoop;
	alias CFRunLoopRef = __CFRunLoop*;
	struct __CFRunLoopSource;
	alias CFRunLoopSourceRef = __CFRunLoopSource*;

	alias CFTimeInterval = double;

	enum CFRunLoopRunResult : int {
	    kCFRunLoopRunFinished = 1,
	    kCFRunLoopRunStopped = 2,
	    kCFRunLoopRunTimedOut = 3,
	    kCFRunLoopRunHandledSource = 4
	}

	extern const CFStringRef kCFRunLoopDefaultMode;
	extern const CFStringRef kCFRunLoopCommonModes;

	CFRunLoopRef CFRunLoopGetMain() @nogc;
	CFRunLoopRef CFRunLoopGetCurrent() @nogc;
	void CFRunLoopAddSource(CFRunLoopRef rl, CFRunLoopSourceRef source, CFRunLoopMode mode) @nogc;
	CFRunLoopRunResult CFRunLoopRunInMode(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled);
}

static if (!is(CFFileDescriptorRef)) {
	alias CFFileDescriptorNativeDescriptor = int;

	struct __CFFileDescriptor;
	alias CFFileDescriptorRef = __CFFileDescriptor*;

	/* Callback Reason Types */
	enum CFOptionFlags {
	    kCFFileDescriptorReadCallBack = 1UL << 0,
	    kCFFileDescriptorWriteCallBack = 1UL << 1
	}

	alias CFFileDescriptorCallBack = void function(CFFileDescriptorRef f, CFOptionFlags callBackTypes, void* info);

	struct CFFileDescriptorContext {
	    CFIndex version_;
	    void* info;
	    void* function(void *info) retain;
	    void function(void *info) release;
	    CFStringRef function(void *info) copyDescription;
	}

	CFTypeID CFFileDescriptorGetTypeID() @nogc;
	CFFileDescriptorRef	CFFileDescriptorCreate(CFAllocatorRef allocator, CFFileDescriptorNativeDescriptor fd, Boolean closeOnInvalidate, CFFileDescriptorCallBack callout, const(CFFileDescriptorContext)* context) @nogc;
	CFFileDescriptorNativeDescriptor CFFileDescriptorGetNativeDescriptor(CFFileDescriptorRef f) @nogc;
	void CFFileDescriptorGetContext(CFFileDescriptorRef f, CFFileDescriptorContext* context) @nogc;
	void CFFileDescriptorEnableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes) @nogc;
	void CFFileDescriptorDisableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes) @nogc;
	void CFFileDescriptorInvalidate(CFFileDescriptorRef f) @nogc;
	Boolean CFFileDescriptorIsValid(CFFileDescriptorRef f) @nogc;
	CFRunLoopSourceRef CFFileDescriptorCreateRunLoopSource(CFAllocatorRef allocator, CFFileDescriptorRef f, CFIndex order) @nogc;
}
