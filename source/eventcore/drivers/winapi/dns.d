module eventcore.drivers.winapi.dns;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;


final class WinAPIEventDriverDNS : EventDriverDNS {
@safe: /*@nogc:*/ nothrow:

	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		import std.typecons : scoped;
		import std.utf : toUTF16z;

		auto id = DNSLookupID(0, 0);

		static immutable ushort[] addrfamilies = [AF_INET, AF_INET6];

		const(WCHAR)* namew;
		try namew = name.toUTF16z;
		catch (Exception e) return DNSLookupID.invalid;

		foreach (af; addrfamilies) {
			//if (family != af && family != AF_UNSPEC) continue;

			SOCKADDR_STORAGE sa;
			INT addrlen = sa.sizeof;
			auto ret = () @trusted { return WSAStringToAddressW(namew, af, null, cast(sockaddr*)&sa, &addrlen); } ();
			if (ret != 0) continue;

			scope addr = new RefAddress(() @trusted { return cast(sockaddr*)&sa; } (), addrlen);
			RefAddress[1] addrs;
			addrs[0] = addr;
			on_lookup_finished(id, DNSStatus.ok, () @trusted { return addrs[]; } ()); // NOTE DIP-1000 doesn't allow this, even if the parameter is scope
			return id;
		}

		version (none) { // Windows 8+
			LookupStatus status;
			status.task = Task.getThis();
			status.driver = this;
			status.finished = false;

			WSAOVERLAPPEDX overlapped;
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.hEvent = cast(HANDLE)cast(void*)&status;

			void* aif;
			ADDRINFOEXW addr_hint;
			ADDRINFOEXW* addr_ret;
			addr_hint.ai_family = family;
			addr_hint.ai_socktype = SOCK_STREAM;
			addr_hint.ai_protocol = IPPROTO_TCP;

			enforce(GetAddrInfoExW(namew, null, NS_DNS, null, &addr_hint, &addr_ret, null, &overlapped, &onDnsResult, null) == 0, "Failed to lookup host");
			while (!status.finished) m_core.yieldForEvent();
			enforce(!status.error, "Failed to lookup host: "~to!string(status.error));

			aif = addr_ret;
			addr.family = cast(ubyte)addr_ret.ai_family;
			switch (addr.family) {
				default: assert(false, "Invalid address family returned from host lookup.");
				case AF_INET: addr.sockAddrInet4 = *cast(sockaddr_in*)addr_ret.ai_addr; break;
				case AF_INET6: addr.sockAddrInet6 = *cast(sockaddr_in6*)addr_ret.ai_addr; break;
			}
			FreeAddrInfoExW(addr_ret);
		} else {
			ADDRINFOW* results;
			if (auto ret = () @trusted { return GetAddrInfoW(namew, null, null, &results); } ()) {
				on_lookup_finished(id, DNSStatus.error, null);
				return id;
			}

			scope(failure) assert(false);
			() @trusted {
				typeof(scoped!RefAddress())[16] addr_storage = [
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress()
				];
				RefAddress[16] buf;
				size_t naddr = 0;
				while (results) {
					RefAddress addr = addr_storage[naddr];
					addr.set(results.ai_addr, cast(socklen_t)results.ai_addrlen);
					buf[naddr++] = addr;
					results = results.ai_next;
				}

				on_lookup_finished(id, DNSStatus.ok, buf[0 .. naddr]);
			} ();
		}

		return id;
	}

	void cancelLookup(DNSLookupID handle)
	{
		if (!isValid(handle)) return;

		assert(false, "TODO!");
	}

	override bool isValid(DNSLookupID handle)
	const {
		return handle == DNSLookupID(0, 0);
	}
}
