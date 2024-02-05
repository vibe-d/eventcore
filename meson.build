project(
	'eventcore',
	['d'],
	license: 'MIT',
	meson_version: '>=1.3.1',
)

default_driver = 'select'
host_system = host_machine.system()

host_is_posix = false
host_is_osx = false
host_is_windows = false
host_is_bsd = false
host_is_linux = false

# Determine the default driver if 'driver' was not explicitly set
if host_system == 'linux'
	host_is_linux = true
	host_is_posix = true
elif host_system == 'windows'
	host_is_windows = true
elif host_system == 'dragonfly' or host_system == 'freebsd' or host_system == 'netbsd' or host_system == 'openbsd'
	host_is_bsd = true
	host_is_posix = true
else
	# What are we running on?
	default_driver = 'generic'
endif

if host_is_linux
	default_driver = 'epoll'
elif host_is_osx
	default_driver = 'cfrunloop'
elif host_is_windows
	default_driver = 'winapi'
elif host_is_bsd
	default_driver = 'kqueue'
elif host_is_posix
	default_driver = 'select'
endif

# Optional dependencies
libasync_dep = dependency('libasync', version: '~>0.8.2', required: false)
gaia_dep = dependency('anl', required: get_option('use_gaia'))

# Driver logic
driver_opt = get_option('driver')
if driver_opt == 'auto'
	driver_opt = default_driver
endif

eventcore_build_versions = []
eventcore_extra_deps = []

if driver_opt == 'epoll' 
	if not host_is_linux
		error('epoll driver is only supported on Linux')
	endif
	eventcore_build_versions += 'EventcoreEpollDriver'
	if gaia_dep.found()
		eventcore_extra_deps += gaia_dep
		eventcore_build_versions += 'EventcoreUseGAIA'
	endif
elif driver_opt == 'cfrunloop' 
	if not host_is_osx
		error('cfrunloop driver is only supported on OSX')
	endif
	eventcore_build_versions += 'EventcoreCFRunLoopDriver'
elif driver_opt == 'kqueue'
	if not host_is_bsd
		error('kqueue driver is only supported on BSD variants (including OSX)')
	endif
	eventcore_build_versions += 'EventcoreKqueueDriver'
elif driver_opt == 'winapi'
	if not host_is_windows
		error('winapi driver is only supported on Windows')
	endif
	eventcore_build_versions += 'EventcoreWinAPIDriver'
elif driver_opt == 'select' 
	if not (host_is_posix or host_is_windows)
		error('select driver is only supported on POSIX-like systems and Windows')
	endif
	eventcore_build_versions += 'EventcoreSelectDriver'
elif driver_opt == 'libasync' 
	if not libasync_dep.found()
		error('libasync could not be found, but is required for the libasync driver')
	endif
	eventcore_build_versions += 'EventcoreLibasyncDriver'
	eventcore_extra_deps += libasync_dep
elif driver_opt == 'generic'
	# Defines eventDriver as the generic EventDriver interface. Setup must be done manually.
else
	error('No combination of driver and compatible host machine OS specified')
endif

summary(
	{
		'Chosen driver': driver_opt,
		'Default driver': default_driver,
		'Using GAIA': gaia_dep.found()
	}, 
	bool_yn: true
)
	

subdir('source/eventcore')
imports_dir = include_directories('source/')

taggedalgebraic_dep = subproject('taggedalgebraic').get_variable('taggedalgebraic_dep')

# to avoid duplication
eventcore_internal_deps = declare_dependency(
	include_directories: imports_dir,
	dependencies: [taggedalgebraic_dep],
	d_module_versions: eventcore_build_versions,
)

eventcore_lib = library(
	'eventcore',
	sources: eventcore_src,
	dependencies: [eventcore_internal_deps, eventcore_extra_deps],
	install: true,
)

eventcore_dep = declare_dependency(
	dependencies: eventcore_internal_deps,
	link_with: eventcore_lib,
)

test_exe = executable(
	'eventcore_test',
	sources: eventcore_src,
	dependencies: [eventcore_dep, taggedalgebraic_dep, eventcore_extra_deps],
	d_unittest: true,
	link_args: '-main',
)

test('test_eventcore', test_exe)
