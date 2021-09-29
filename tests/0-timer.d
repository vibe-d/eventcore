/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import core.time : Duration, MonoTime, msecs;
import std.stdio : writefln;

MonoTime s_startTime;
int s_cnt = 0;
bool s_done;

void main()
{
	s_startTime = MonoTime.currTime();

	auto tm = eventDriver.timers.create();
	eventDriver.timers.wait(tm, (tm) nothrow @safe {
		Duration dur;

		{
			scope (failure) assert(false);
			dur = MonoTime.currTime() - s_startTime;
		}

		try {
			assert(dur > 1200.msecs - 2.msecs, (dur - 1200.msecs).toString());
			assert(dur < 1300.msecs + 100.msecs, (dur - 1200.msecs).toString());
		} catch (Exception e) assert(false, e.msg);

		s_startTime += dur;

		eventDriver.timers.set(tm, 300.msecs, 300.msecs);

		void secondTier(TimerID timer) nothrow @safe {
			try {
				auto dur = MonoTime.currTime() - s_startTime;
				s_cnt++;
				assert(dur > 300.msecs * s_cnt - 2.msecs, (dur - 300.msecs * s_cnt).toString());
				assert(dur < 300.msecs * s_cnt + 100.msecs, (dur - 300.msecs * s_cnt).toString());
				assert(s_cnt <= 3);

				if (s_cnt == 3) {
					s_done = true;
					eventDriver.timers.stop(timer);
				} else eventDriver.timers.wait(tm, &secondTier);
			} catch (Exception e) {
				assert(false, e.msg);
			}
		}

		eventDriver.timers.wait(tm, &secondTier);
	});

	eventDriver.timers.set(tm, 1200.msecs, 0.msecs);

	// test if stop() produces a callback with fire==false
	bool got_event = false;
	auto tm2 = eventDriver.timers.create();
	eventDriver.timers.wait(tm2, (t, fired) { assert(!fired); got_event = true; });
	eventDriver.timers.set(tm2, 100.msecs, 0.msecs);
	eventDriver.timers.stop(tm2);
	assert(got_event);


	// test that cancelWait() does not produce a callback
	eventDriver.timers.wait(tm2, (t, fired) { assert(false); });
	eventDriver.timers.set(tm2, 100.msecs, 0.msecs);
	eventDriver.timers.cancelWait(tm2);
	eventDriver.timers.stop(tm2);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
