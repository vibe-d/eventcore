module eventcore.drivers.libasync.dns;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.core;
import eventcore.internal.utils : ChoppedVector, print;
import libasync : NetworkAddress;
import libasync.dns : AsyncDNS;


final class LibasyncEventDriverDNS : EventDriverDNS {
@safe: /*@nogc:*/ nothrow:

	private {
		struct Slot {
			uint refCount;
			uint validation;
			shared AsyncDNS resolver;
			DNSLookupCallback callback;
			bool live;
		}

		LibasyncEventDriverCore m_core;
		ChoppedVector!Slot m_slots;
		size_t[] m_free;
		size_t m_live;
	}

	this(LibasyncEventDriverCore core)
	{
		m_core = core;
	}

	package @property bool hasLeakedHandles()
	{
		if (!m_live) return false;
		print("Warning: %s DNS lookups leaked at libasync driver shutdown.", m_live);
		return true;
	}

	void dispose() {}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	@trusted {
		auto id = allocSlot();
		auto idx = cast(size_t)id;
		auto dns = new shared AsyncDNS(m_core.evloop);
		m_slots[idx].resolver = dns;
		m_slots[idx].callback = on_lookup_finished;
		m_core.addWaiter();

		dns.handler((NetworkAddress addr) {
			finish(idx, addr);
		});

		if (!dns.resolveHost(name, false, true)) {
			// force_async unsupported on this backend — resolve on this thread
			auto addr = m_core.evloop.resolveHost(name);
			finish(idx, addr);
		}
		return id;
	}

	override void cancelLookup(DNSLookupID handle)
	{
		if (!isValid(handle)) return;
		auto s = &m_slots[cast(size_t)handle];
		s.callback = null;
		s.live = false;
		m_core.removeWaiter();
		freeSlot(cast(size_t)handle);
	}

	override bool isValid(DNSLookupID handle)
	const @nogc {
		if (handle == DNSLookupID.invalid) return false;
		auto v = cast(size_t)handle;
		if (v >= m_slots.length) return false;
		auto s = &m_slots[v];
		return s.live && s.validation == handle.validationCounter;
	}

	private void finish(size_t idx, NetworkAddress addr)
	@trusted {
		if (idx >= m_slots.length || !m_slots[idx].live) return;
		auto s = &m_slots[idx];
		auto cb = s.callback;
		s.callback = null;
		s.live = false;
		m_core.removeWaiter();
		auto vc = s.validation;
		freeSlot(idx);
		if (!cb) return;

		if (addr.family == 0) {
			cb(DNSLookupID(idx, vc), DNSStatus.error, null);
			return;
		}
		import core.stdc.string : memcpy;
		version (Posix) import core.sys.posix.sys.socket : sockaddr, sockaddr_storage;
		version (Windows) import core.sys.windows.winsock2 : sockaddr, sockaddr_storage;
		sockaddr_storage ss;
		memcpy(&ss, addr.sockAddr, addr.sockAddrLen);
		scope ra = new RefAddress(cast(sockaddr*)&ss, addr.sockAddrLen);
		RefAddress[1] arr = [ra];
		cb(DNSLookupID(idx, vc), DNSStatus.ok, arr);
	}

	private DNSLookupID allocSlot()
	{
		size_t idx;
		if (m_free.length) {
			idx = m_free[$ - 1];
			m_free = m_free[0 .. $ - 1];
			m_free = m_free[0 .. $];
		} else {
			idx = m_slots.length;
		}
		m_slots[idx] = Slot.init;
		m_slots[idx].refCount = 1;
		m_slots[idx].validation++;
		m_slots[idx].live = true;
		m_live++;
		return DNSLookupID(idx, m_slots[idx].validation);
	}

	private void freeSlot(size_t idx)
	{
		if (idx >= m_slots.length) return;
		auto s = &m_slots[idx];
		s.resolver = null;
		s.live = false;
		s.validation++;
		m_free ~= idx;
		if (m_live) m_live--;
	}
}
