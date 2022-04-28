module eventcore.internal.consumablequeue;

import eventcore.internal.utils : mallocNT, freeNT;


/** FIFO queue with support for chunk-wise consumption.
*/
final class ConsumableQueue(T)
{
	@safe nothrow:

	private {
		struct Slot {
			T value;
			uint rc;
		}
		Slot[] m_storage;
		size_t m_capacityMask;
		size_t m_first;
		size_t m_consumedCount;
		size_t m_pendingCount;
	}

	~this()
	@trusted @nogc nothrow {
		if (m_storage !is null)
			freeNT(m_storage);
	}

	@property size_t length() const { return m_pendingCount; }

	@property bool empty() const { return length == 0; }

	/** Inserts a single element into the queue.
	*/
	@safe void put(T element)
	{
		reserve(1);
		auto idx = (m_first + m_consumedCount + m_pendingCount++) & m_capacityMask;
		m_storage[idx] = Slot(element, 0);
	}

	/** Reserves space for inserting at least `count` elements.
	*/
	void reserve(size_t count)
	@safe {
		auto min_capacity = m_consumedCount + m_pendingCount + count;
		if (min_capacity <= m_storage.length)
			return;

		auto new_capacity = m_storage.length ? m_storage.length : 16;
		while (new_capacity < min_capacity) new_capacity *= 2;
		auto new_capacity_mask = new_capacity - 1;

		auto new_storage = mallocNT!Slot(new_capacity);
		foreach (i; 0 .. m_consumedCount + m_pendingCount)
			new_storage[(m_first + i) & new_capacity_mask] = m_storage[(m_first + i) & m_capacityMask];

		() @trusted {
			if (m_storage !is null)
				freeNT(m_storage);
			m_storage = new_storage;
		} ();
		m_capacityMask = new_capacity_mask;
	}

	void removePending(T item)
	{
		foreach (i; 0 .. m_pendingCount)
			if (getPendingAt(i) == item) {
				if (m_pendingCount > 1)
					getPendingAt(i) = getPendingAt(m_pendingCount-1);
				m_pendingCount--;
				break;
			}
	}

	/** Consumes all elements of the queue and returns a range containing the
		consumed elements.

		Any elements added after the call to `consume` will not show up in the
		returned range.
	*/
	ConsumedRange consume()
	@safe {
		if (!m_pendingCount) return ConsumedRange(null, 0, 0);
		auto first = (m_first + m_consumedCount) % m_storage.length;
		auto count = m_pendingCount;
		m_consumedCount += count;
		m_pendingCount = 0;
		return ConsumedRange(this, first, count);
	}

	T consumeOne()
	{
		assert(!empty);
		auto ret = m_storage[(m_first + m_consumedCount) & m_capacityMask].value;
		if (m_consumedCount) m_consumedCount++;
		else m_first = (m_first + 1) & m_capacityMask;
		m_pendingCount--;
		return ret;
	}

	static struct ConsumedRange {
		nothrow:

		private {
			ConsumableQueue m_queue;
			size_t m_first;
			size_t m_count;
		}

		this(ConsumableQueue queue, size_t first, size_t count)
		{
			if (count) {
				m_queue = queue;
				m_first = first;
				m_count = count;
				m_queue.m_storage[first & m_queue.m_capacityMask].rc++;
			}
		}

		this(this)
		{
			if (m_count)
				m_queue.m_storage[m_first & m_queue.m_capacityMask].rc++;
		}

		~this()
		{
			if (m_count)
				m_queue.consumed(m_first, false);
		}

		@property ConsumedRange save() { return this; }

		@property bool empty() const { return m_count == 0; }

		@property size_t length() const { return m_count; }

		@property ref inout(T) front() inout { return m_queue.m_storage[m_first & m_queue.m_capacityMask].value; }

		void popFront()
		{
			m_queue.consumed(m_first, m_count > 1);
			m_first++;
			m_count--;
		}

		ref inout(T) opIndex(size_t idx) inout { return m_queue.m_storage[(m_first + idx) & m_queue.m_capacityMask].value; }

		int opApply(scope int delegate(ref T) @safe nothrow del)
		{
			foreach (i; 0 .. m_count)
				if (auto ret = del(m_queue.m_storage[(m_first + i) & m_queue.m_capacityMask].value))
					return ret;
			return 0;
		}
	}

	private void consumed(size_t first, bool shift_up)
	{
		if (shift_up) {
			m_storage[(first+1) & m_capacityMask].rc++;
			if (!--m_storage[first & m_capacityMask].rc && first == m_first) {
				m_first++;
				m_consumedCount--;
			}
		} else {
			m_storage[first & m_capacityMask].rc--;
			if (first == m_first)
				while (m_consumedCount > 0 && !m_storage[m_first & m_capacityMask].rc) {
					m_first++;
					m_consumedCount--;
				}
		}
		m_first = m_first & m_capacityMask;
	}

	private scope ref T getPendingAt(size_t idx)
	{
		assert(idx < m_pendingCount, "Pending item index out of bounds.");
		return m_storage[(m_first + m_consumedCount + idx) & m_capacityMask].value;
	}
}

///
unittest {
	import std.algorithm.comparison : equal;
	auto q = new ConsumableQueue!int;

	q.put(1);
	q.put(2);
	q.put(3);
	assert(q.m_consumedCount == 0 && q.m_pendingCount == 3);

	auto r1 = q.consume;
	assert(r1.length == 3);
	assert(q.m_consumedCount == 3 && q.m_pendingCount == 0);

	q.put(4);
	q.put(5);
	assert(q.m_consumedCount == 3 && q.m_pendingCount == 2);

	auto r2 = q.consume;
	assert(r2.length == 2);
	assert(q.m_consumedCount == 5 && q.m_pendingCount == 0);

	q.put(6);
	assert(q.m_consumedCount == 5 && q.m_pendingCount == 1);

	auto r3 = r1.save;
	assert(r3.length == 3);

	assert(q.m_consumedCount == 5 && q.m_pendingCount == 1);
	assert((&r2).equal([4, 5]));
	assert(q.m_consumedCount == 5 && q.m_pendingCount == 1);
	assert((&r1).equal([1, 2, 3]));
	assert(q.m_consumedCount == 5 && q.m_pendingCount == 1);
	assert((&r3).equal([1, 2, 3]));
	assert(q.m_consumedCount == 0 && q.m_pendingCount == 1);

	assert(q.length == 1);
	assert(q.consumeOne == 6);
	assert(q.length == 0);
	assert(q.m_consumedCount == 0);

	foreach (i; 7 .. 15) q.put(i);
	assert(q.consume.equal([7, 8, 9, 10, 11, 12, 13, 14]));
	q.put(15);
	assert(q.consume.equal([15]));
	q.put(16);
	assert(q.consume.equal([16]));
	q.put(17);
	assert(q.consume.equal([17]));
	assert(q.consume.empty);
}

unittest {
	import std.range : iota;
	import std.algorithm.comparison : equal;

	auto q = new ConsumableQueue!int;
	foreach (i; 0 .. 14)
		q.put(i);
	assert(q.consume().equal(iota(14)));
	foreach (i; 0 .. 4)
		q.put(i);
	assert(q.consume().equal(iota(4)));
}


void filterPending(alias pred, T)(ConsumableQueue!T q)
@safe {
	size_t ir = 0;
	size_t iw = 0;

	while (ir < q.m_pendingCount) {
		if (!pred(q.getPendingAt(ir))) {
		} else {
			if (ir != iw) q.getPendingAt(iw) = q.getPendingAt(ir);
			iw++;
		}
		ir++;
	}
	q.m_pendingCount = iw;
}


unittest {
	import std.algorithm.comparison : equal;
	import std.range : only;

	auto q = new ConsumableQueue!int;
	foreach (i; 0 .. 14) q.put(i);
	q.filterPending!(i => i % 2 != 0);
	assert(q.consume().equal(only(1, 3, 5, 7, 9, 11, 13)));

	foreach (i; 0 .. 14) q.put(i);
	q.filterPending!(i => i % 3 == 1);
	assert(q.consume().equal(only(1, 4, 7, 10, 13)));
}
