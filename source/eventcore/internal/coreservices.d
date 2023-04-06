module eventcore.internal.coreservices;

import eventcore.internal.corefoundation;

static if (isAppleOS):

nothrow extern(C):

static if (!is(FSEventStreamRef)) {
	alias FSEventStreamCreateFlags = uint;

	enum {
		kFSEventStreamCreateFlagNone  = 0x00000000,
		kFSEventStreamCreateFlagUseCFTypes = 0x00000001,
		kFSEventStreamCreateFlagNoDefer = 0x00000002,
		kFSEventStreamCreateFlagWatchRoot = 0x00000004,
		kFSEventStreamCreateFlagIgnoreSelf = 0x00000008,
		kFSEventStreamCreateFlagFileEvents = 0x00000010,
		kFSEventStreamCreateFlagMarkSelf = 0x00000020,
		kFSEventStreamCreateFlagUseExtendedData = 0x00000040
	}

	//#define kFSEventStreamEventExtendedDataPathKey      CFSTR("path")
	//#define kFSEventStreamEventExtendedFileIDKey        CFSTR("fileID")

	alias FSEventStreamEventFlags = uint;

	enum {
		kFSEventStreamEventFlagNone   = 0x00000000,
		kFSEventStreamEventFlagMustScanSubDirs = 0x00000001,
		kFSEventStreamEventFlagUserDropped = 0x00000002,
		kFSEventStreamEventFlagKernelDropped = 0x00000004,
		kFSEventStreamEventFlagEventIdsWrapped = 0x00000008,
		kFSEventStreamEventFlagHistoryDone = 0x00000010,
		kFSEventStreamEventFlagRootChanged = 0x00000020,
		kFSEventStreamEventFlagMount  = 0x00000040,
		kFSEventStreamEventFlagUnmount = 0x00000080,
		kFSEventStreamEventFlagItemCreated = 0x00000100,
		kFSEventStreamEventFlagItemRemoved = 0x00000200,
		kFSEventStreamEventFlagItemInodeMetaMod = 0x00000400,
		kFSEventStreamEventFlagItemRenamed = 0x00000800,
		kFSEventStreamEventFlagItemModified = 0x00001000,
		kFSEventStreamEventFlagItemFinderInfoMod = 0x00002000,
		kFSEventStreamEventFlagItemChangeOwner = 0x00004000,
		kFSEventStreamEventFlagItemXattrMod = 0x00008000,
		kFSEventStreamEventFlagItemIsFile = 0x00010000,
		kFSEventStreamEventFlagItemIsDir = 0x00020000,
		kFSEventStreamEventFlagItemIsSymlink = 0x00040000,
		kFSEventStreamEventFlagOwnEvent = 0x00080000,
		kFSEventStreamEventFlagItemIsHardlink = 0x00100000,
		kFSEventStreamEventFlagItemIsLastHardlink = 0x00200000,
		kFSEventStreamEventFlagItemCloned = 0x00400000
	}

	alias FSEventStreamEventId = ulong;

	enum kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFFUL;


	struct __FSEventStream;
	alias FSEventStreamRef = __FSEventStream*;
	alias ConstFSEventStreamRef = const(__FSEventStream)*;

	struct FSEventStreamContext {
	  CFIndex version_;
	  void* info;
	  CFAllocatorRetainCallBack retain;
	  CFAllocatorReleaseCallBack release;
	  CFAllocatorCopyDescriptionCallBack copyDescription;
	}

	alias FSEventStreamCallback = void function(ConstFSEventStreamRef streamRef,
		void* clientCallBackInfo, size_t numEvents, void* eventPaths,
		const(FSEventStreamEventFlags)* eventFlags,
		const(FSEventStreamEventId)* eventIds);

	FSEventStreamRef FSEventStreamCreate(CFAllocatorRef allocator,
		FSEventStreamCallback callback, FSEventStreamContext* context,
		CFArrayRef pathsToWatch, FSEventStreamEventId sinceWhen,
		CFTimeInterval latency, FSEventStreamCreateFlags flags);

	void FSEventStreamRetain(FSEventStreamRef streamRef);
	void FSEventStreamRelease(FSEventStreamRef streamRef);

	void FSEventStreamScheduleWithRunLoop(FSEventStreamRef streamRef,
		CFRunLoopRef runLoop, CFStringRef runLoopMode);

	void FSEventStreamUnscheduleFromRunLoop(FSEventStreamRef streamRef,
		CFRunLoopRef runLoop, CFStringRef runLoopMode);

	void FSEventStreamInvalidate(FSEventStreamRef streamRef);

	Boolean FSEventStreamStart(FSEventStreamRef streamRef);

	FSEventStreamEventId FSEventStreamFlushAsync(FSEventStreamRef streamRef);

	void FSEventStreamFlushSync(FSEventStreamRef streamRef);

	void FSEventStreamStop(FSEventStreamRef streamRef);
}
