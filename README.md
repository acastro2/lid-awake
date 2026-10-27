# Lid Awake

A tiny macOS menu bar app that keeps a MacBook awake with the lid shut, and
nothing else.

macOS sleeps a laptop when you close the lid unless an external display,
keyboard and mouse are attached. This app skips that requirement by setting
`pmset -a disablesleep`, the one switch that overrides lid sleep. No external
hardware needed.

Two guards stop that switch from cooking the machine or flattening the battery.

## What it does

One click, as root:

```sh
pmset -a disablesleep 1     # on  - closing the lid no longer sleeps the Mac
pmset -a disablesleep 0     # off - normal sleep
```

Nothing else. No network, no telemetry, no background timer beyond a 4 second
status poll.

## Requirements

- macOS 13 or later, Apple silicon or Intel
- Xcode command line tools (`swiftc`)
- Admin rights, because the sleep switch needs root

## Install

```sh
./build.sh
```

That compiles `main.swift`, ad-hoc signs the app, installs it to
`/Applications/Lid Awake.app`, installs a login agent at
`~/Library/LaunchAgents/`, and starts it.

Build products land in `build/` and are not tracked.

## The sudoers rule

`sudo` needs to run exactly three commands without a password prompt:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset sleepnow
```

Install the rule once:

```sh
sudo ./sudoers.sh
```

The script writes `/etc/sudoers.d/lidawake`, validates it with `visudo -c`
before moving it into place, and grants it to the `%admin` group. It allows
those three command lines and nothing else. To write it by hand instead,
use `visudo -f /etc/sudoers.d/lidawake`.

## Menu

- The toggle awakens the Mac indefinitely. There is no timer.
- Live CPU die temperature and lid state.
- The power line turns orange on battery.

## Guards

**Battery guard**, on by default. The flag ignores the power source, so the
moment the Mac runs on battery the app sets `disablesleep 0`. Untick it in the
menu if you want lid-awake on battery on purpose. A manual "on" while on
battery unticks the guard for you: the click wins.

**Thermal guard**. When the flag is on, the lid is shut, and the hottest CPU
die sensor reads 90 C or more, the app drops the flag, forces sleep and beeps.
It stays tripped until the die falls below 75 C, then you re-enable by hand.

Lid shut is part of the condition on purpose: 90 C with the lid open is just a
busy machine, and macOS handles that.

Tune the thresholds:

```sh
defaults write com.github.acastro2.lidawake TripC  -float 85
defaults write com.github.acastro2.lidawake ClearC -float 70
```

**Lock after 5 min**, off by default. When ticked, the screen locks after 5
minutes without keyboard or mouse input, once per idle period. It is a lock,
not sleep: the Mac keeps running.

Test it without waiting:

```sh
"/Applications/Lid Awake.app/Contents/MacOS/LidAwake" --locknow
```

Other switches:

```sh
# print temperature, lid state, power, flag and settings
"/Applications/Lid Awake.app/Contents/MacOS/LidAwake" --selftest

# flip the sleep flag through the same path the menu uses
"/Applications/Lid Awake.app/Contents/MacOS/LidAwake" --toggle
```

## How the sensors are read

Temperature comes from the `PMU tdie*` sensors through IOHID, with no root and
no helper binary: `IOHIDEventSystemClientCreateWithType` and friends, resolved
with `dlsym`.

Screen lock uses `SACLockScreenImmediate` from `login.framework`, falling back
to `pmset displaysleepnow` when the symbol is unavailable.

Both are private interfaces. They work on current macOS releases and can break
in any update. That is the price of not needing a privileged helper.

## Limits

- With the toggle on, closing the lid and putting the Mac in a bag keeps it
  running. That is heat and battery drain. The guards reduce the risk, they do
  not remove it. Never leave an awake Mac in a bag.
- Display sleep is untouched. The Mac stays awake, the screen still goes dark
  on its normal timer.
- The flag is global and survives reboots. Quitting the app does not reset it.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.github.acastro2.lidawake
rm -f ~/Library/LaunchAgents/com.github.acastro2.lidawake.plist
rm -rf "/Applications/Lid Awake.app"
sudo rm -f /etc/sudoers.d/lidawake
sudo pmset -a disablesleep 0
```

## License

MIT
