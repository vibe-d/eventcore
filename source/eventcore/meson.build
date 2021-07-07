eventcore_src = [
	'core.d',
	'driver.d',
	'drivers/libasync.d',
	'drivers/posix/cfrunloop.d',
	'drivers/posix/dns.d',
	'drivers/posix/driver.d',
	'drivers/posix/epoll.d',
	'drivers/posix/events.d',
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
	'internal/corefoundation.d',
	'internal/dlist.d',
	'internal/ioworker.d',
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
	dependencies: [taggedalgebraic_dep, eventcore_extra_deps],
	d_module_versions: eventcore_build_versions
)

pkgc = import('pkgconfig')

pkgc.generate(
	eventcore_lib,
	subdirs: 'd/eventcore',
	d_module_versions: eventcore_build_versions
)

# This is using install_subdir instead of install_headers, since
# install_headers flattens the headers directory, it turns
# ├ ...
# ├ driver.d
# ├ drivers
# │  ├ libasync.d
# │  ├ ...
# │  └ winapi
# │    └ ...
# ├ ...
# └ socket.d
# 
# into
# 
# ├ ...
# ├ drivers.d
# ├ libasync.d
# ├ ...
# └ socket.d
# 

install_subdir(
	'../',
	install_dir: 'include/d/eventcore/eventcore',
)

test_exe = executable(
	'eventcore_test',
	eventcore_src,
	include_directories: include_directories('../'),
	d_unittest: true,
	d_args: meson.get_compiler('d').unittest_args(),
	link_args: '-main',
	dependencies: taggedalgebraic_dep,
)

test('test_eventcore', test_exe)
