eventcore_src = [
	'core.d',
	'driver.d',
	'drivers/libasync.d',
	'drivers/posix/dns.d',
	'drivers/posix/driver.d',
	'drivers/posix/epoll.d',
	'drivers/posix/events.d',
	'drivers/posix/io_uring/io_uring.d',
	'drivers/posix/io_uring/files.d',
	'drivers/posix/kqueue.d',
	'drivers/posix/pipes.d',
	'drivers/posix/processes.d',
	'drivers/posix/select.d',
	'drivers/posix/signals.d',
	'drivers/posix/sockets.d',
	'drivers/posix/watchers.d',
	'drivers/threadedfile.d',
	'drivers/timer.d',
	'drivers/winapi/core.d',
	'drivers/winapi/dns.d',
	'drivers/winapi/driver.d',
	'drivers/winapi/events.d',
	'drivers/winapi/files.d',
	'drivers/winapi/pipes.d',
	'drivers/winapi/processes.d',
	'drivers/winapi/signals.d',
	'drivers/winapi/sockets.d',
	'drivers/winapi/watchers.d',
	'internal/consumablequeue.d',
	'internal/dlist.d',
	'internal/utils.d',
	'internal/win32.d',
	'socket.d',

]

eventcore_lib = library(
	'eventcore',
	eventcore_src,
	version: project_version,
	install: true,
	include_directories: include_directories('../'),
	dependencies: taggedalgebraic_dep,
)

pkgc = import('pkgconfig')

pkgc.generate(
	eventcore_lib,
	subdirs: 'd/eventcore',
)

install_headers(
	eventcore_src,
	subdir: 'd/eventcore/eventcore',
)

test_exe = executable(
	'eventcore_test',
	eventcore_src,
	include_directories: include_directories('../'),
	d_unittest: true,
	d_args: '-main',
	dependencies: taggedalgebraic_dep,
)

test('test_eventcore', test_exe)
