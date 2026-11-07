# ConnectBridge build environment (source it):  source env.sh
# Needs Theos, Xcode (iPhoneOS SDK) and rustup; adjust the fallbacks below for your machine.
export THEOS="${THEOS:-$HOME/theos}"

# Xcode: keep DEVELOPER_DIR if set, else the active developer dir when it is a full Xcode, else
# the newest /Applications/*.app that has an iPhoneOS platform (this skips helpers like Xcodes.app).
if [ -z "${DEVELOPER_DIR:-}" ]; then
	case "$(xcode-select -p 2>/dev/null)" in
		*.app/Contents/Developer) ;;
		*)
			for app in /Applications/Xcode*.app; do
				[ -d "$app/Contents/Developer/Platforms/iPhoneOS.platform" ] && export DEVELOPER_DIR="$app/Contents/Developer"
			done
			;;
	esac
fi

# rustup (Homebrew keeps it out of the PATH) and cargo
for dir in "$(brew --prefix rustup 2>/dev/null)/bin" "$HOME/.cargo/bin"; do
	[ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

# Theos refuses project paths that contain spaces.
