# probe.sh seed for PROBE_SCENARIO=welcome: a new user (the tour's welcome card) with 5 uses.
defaults write "$1" tourAudience -string new
defaults write "$1" launchAtLoginPromptUses -int 5
