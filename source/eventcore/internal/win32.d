module eventcore.internal.win32;

version (Windows):

public import core.sys.windows.windows;
public import core.sys.windows.winsock2;
public import core.stdc.config: c_ulong;

extern(System) nothrow:

enum {
	FD_READ = 0x0001,
	FD_WRITE = 0x0002,
	FD_OOB = 0x0004,
	FD_ACCEPT = 0x0008,
	FD_CONNECT = 0x0010,
	FD_CLOSE = 0x0020,
	FD_QOS = 0x0040,
	FD_GROUP_QOS = 0x0080,
	FD_ROUTING_INTERFACE_CHANGE = 0x0100,
	FD_ADDRESS_LIST_CHANGE = 0x0200
}


enum {
	WSA_FLAG_OVERLAPPED = 0x01
}

enum {
	WSAPROTOCOL_LEN  = 255,
	MAX_PROTOCOL_CHAIN = 7,
}

enum WSAEDISCON = 10101;

enum WSA_OPERATION_ABORTED = 995;
enum WSA_IO_PENDING = 997;

struct WSAPROTOCOL_INFOW {
	DWORD            dwServiceFlags1;
	DWORD            dwServiceFlags2;
	DWORD            dwServiceFlags3;
	DWORD            dwServiceFlags4;
	DWORD            dwProviderFlags;
	GUID             ProviderId;
	DWORD            dwCatalogEntryId;
	WSAPROTOCOLCHAIN ProtocolChain;
	int              iVersion;
	int              iAddressFamily;
	int              iMaxSockAddr;
	int              iMinSockAddr;
	int              iSocketType;
	int              iProtocol;
	int              iProtocolMaxOffset;
	int              iNetworkByteOrder;
	int              iSecurityScheme;
	DWORD            dwMessageSize;
	DWORD            dwProviderReserved;
	WCHAR[WSAPROTOCOL_LEN+1] szProtocol;
}

struct WSAPROTOCOLCHAIN {
	int ChainLen;
	DWORD[MAX_PROTOCOL_CHAIN] ChainEntries;
}

struct WSABUF {
	size_t   len;
	ubyte *buf;
}

struct ADDRINFOEXW {
	int ai_flags;
	int ai_family;
	int ai_socktype;
	int ai_protocol;
	size_t ai_addrlen;
	LPCWSTR ai_canonname;
	sockaddr* ai_addr;
	void* ai_blob;
	size_t ai_bloblen;
	GUID* ai_provider;
	ADDRINFOEXW* ai_next;
}

struct ADDRINFOA {
	int ai_flags;
	int ai_family;
	int ai_socktype;
	int ai_protocol;
	size_t ai_addrlen;
	LPSTR ai_canonname;
	sockaddr* ai_addr;
	ADDRINFOA* ai_next;
}

struct ADDRINFOW {
	int ai_flags;
	int ai_family;
	int ai_socktype;
	int ai_protocol;
	size_t ai_addrlen;
	LPWSTR ai_canonname;
	sockaddr* ai_addr;
	ADDRINFOW* ai_next;
}

// https://msdn.microsoft.com/en-us/library/windows/desktop/dd877220(v=vs.85).aspx
struct tcp_keepalive {
	c_ulong onoff;
	c_ulong keepalivetime;
	c_ulong keepaliveinterval;
};

// https://gist.github.com/piscisaureus/906386#file-winsock2-h-L1099
enum : DWORD {
	IOC_VENDOR = 0x18000000,
	IOC_OUT = 0x40000000,
	IOC_IN = 0x80000000
}

DWORD _WSAIOW(DWORD x, DWORD y) pure @safe
{
	return IOC_IN | x | y;
}

enum : DWORD {
	SIO_KEEPALIVE_VALS = _WSAIOW(IOC_VENDOR, 4)
}

struct WSAPROTOCOL_INFO {
	DWORD            dwServiceFlags1;
	DWORD            dwServiceFlags2;
	DWORD            dwServiceFlags3;
	DWORD            dwServiceFlags4;
	DWORD            dwProviderFlags;
	GUID             ProviderId;
	DWORD            dwCatalogEntryId;
	WSAPROTOCOLCHAIN ProtocolChain;
	int              iVersion;
	int              iAddressFamily;
	int              iMaxSockAddr;
	int              iMinSockAddr;
	int              iSocketType;
	int              iProtocol;
	int              iProtocolMaxOffset;
	int              iNetworkByteOrder;
	int              iSecurityScheme;
	DWORD            dwMessageSize;
	DWORD            dwProviderReserved;
	CHAR[WSAPROTOCOL_LEN+1] szProtocol;
}
alias SOCKADDR = sockaddr;

alias LPWSAOVERLAPPED_COMPLETION_ROUTINEX = void function(DWORD, DWORD, WSAOVERLAPPEDX*, DWORD);
alias LPLOOKUPSERVICE_COMPLETION_ROUTINE = void function(DWORD, DWORD, WSAOVERLAPPEDX*);
alias LPCONDITIONPROC = void*;
alias LPTRANSMIT_FILE_BUFFERS = void*;

int WSARecv(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesRecvd, DWORD* lpFlags, const(WSAOVERLAPPEDX)* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
int WSARecvFrom(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesRecvd, DWORD* lpFlags, SOCKADDR *lpFrom, LPINT lpFromlen, const(WSAOVERLAPPEDX)* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
int WSASend(SOCKET s, const(WSABUF)* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesSent, DWORD dwFlags, const(WSAOVERLAPPEDX)* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
int WSASendTo(SOCKET s, const(WSABUF)* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesSent, DWORD dwFlags, const(SOCKADDR) *lpTo, int iToLenin, WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
int GetAddrInfoExW(LPCWSTR pName, LPCWSTR pServiceName, DWORD dwNameSpace, GUID* lpNspId, const ADDRINFOEXW *pHints, ADDRINFOEXW **ppResult, timeval *timeout, WSAOVERLAPPEDX* lpOverlapped, LPLOOKUPSERVICE_COMPLETION_ROUTINE lpCompletionRoutine, HANDLE* lpNameHandle);

@nogc:
SOCKET WSAAccept(SOCKET s, sockaddr *addr, INT* addrlen, LPCONDITIONPROC lpfnCondition, DWORD_PTR dwCallbackData);
int WSAAsyncSelect(SOCKET s, HWND hWnd, uint wMsg, sizediff_t lEvent);
SOCKET WSASocketW(int af, int type, int protocol, WSAPROTOCOL_INFOW *lpProtocolInfo, uint g, DWORD dwFlags);
int WSASendDisconnect(SOCKET s, WSABUF* lpOutboundDisconnectData);
INT WSAStringToAddressA(const(LPSTR) AddressString, INT AddressFamily, const(WSAPROTOCOL_INFO)* lpProtocolInfo, SOCKADDR* lpAddress, INT* lpAddressLength);
INT WSAStringToAddressW(const(LPWSTR) AddressString, INT AddressFamily, const(WSAPROTOCOL_INFOW)* lpProtocolInfo, SOCKADDR* lpAddress, INT* lpAddressLength);
INT WSAAddressToStringW(const(SOCKADDR)* lpsaAddress, DWORD dwAddressLength, const(WSAPROTOCOL_INFO)* lpProtocolInfo, LPWSTR lpszAddressString, DWORD* lpdwAddressStringLength);
int GetAddrInfoW(LPCWSTR pName, LPCWSTR pServiceName, const ADDRINFOW *pHints, ADDRINFOW **ppResult);
int getaddrinfo(LPCSTR pName, LPCSTR pServiceName, const ADDRINFOA *pHints, ADDRINFOA **ppResult);
void FreeAddrInfoW(ADDRINFOW* pAddrInfo);
void FreeAddrInfoExW(ADDRINFOEXW* pAddrInfo);
void freeaddrinfo(ADDRINFOA* ai);
BOOL TransmitFile(SOCKET hSocket, HANDLE hFile, DWORD nNumberOfBytesToWrite, DWORD nNumberOfBytesPerSend, OVERLAPPED* lpOverlapped, LPTRANSMIT_FILE_BUFFERS lpTransmitBuffers, DWORD dwFlags);
BOOL CancelIoEx(HANDLE hFile, LPOVERLAPPED lpOverlapped);
int WSAIoctl(SOCKET s, DWORD dwIoControlCode, void* lpvInBuffer, DWORD cbInBuffer, void* lpvOutBuffer, DWORD cbOutBuffer, DWORD* lpcbBytesReturned, const(WSAOVERLAPPEDX)* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);

/*struct WSAOVERLAPPEDX {
	ULONG_PTR Internal;
	ULONG_PTR InternalHigh;
	union {
		struct {
			DWORD Offset;
			DWORD OffsetHigh;
		}
		PVOID  Pointer;
	}
	HANDLE hEvent;
}*/

alias WSAOVERLAPPEDX = OVERLAPPED;
