/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.datetime : Clock, SysTime, UTC;
import std.stdio : writefln;
import core.time : Duration, msecs;

SysTime s_startTime;
int s_cnt = 0;
bool s_done;

void main()
{
	s_startTime = Clock.currTime(UTC());

	auto tm = eventDriver.timers.create();
	eventDriver.timers.wait(tm, (tm) nothrow @safe {
		Duration dur;

		{
			scope (failure) assert(false);
			dur = Clock.currTime(UTC()) - s_startTime;
		}

		try {
			assert(dur > 200.msecs, (dur - 200.msecs).toString());
			assert(dur < 260.msecs, (dur - 200.msecs).toString());
		} catch (Exception e) assert(false, e.msg);

		s_startTime += dur;

		eventDriver.timers.set(tm, 100.msecs, 100.msecs);

		void secondTier(TimerID timer) nothrow @safe {
			try {
				auto dur = Clock.currTime(UTC()) - s_startTime;
				s_cnt++;
				assert(dur > 100.msecs * s_cnt, (dur - 100.msecs * s_cnt).toString());
				assert(dur < 100.msecs * s_cnt + 60.msecs, (dur - 100.msecs * s_cnt).toString());
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

	eventDriver.timers.set(tm, 200.msecs, 0.msecs);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
