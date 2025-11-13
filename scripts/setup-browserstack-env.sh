#!/bin/zsh
#
# Setup BrowserStack environment variables
# Run: source ./scripts/setup-browserstack-env.sh
#

echo "🔐 Setting up BrowserStack credentials..."
echo ""

# Use zsh-compatible read syntax
echo -n "Enter your BrowserStack Username: "
read BROWSERSTACK_USERNAME

echo -n "Enter your BrowserStack Access Key (hidden): "
read -s BROWSERSTACK_ACCESS_KEY
echo ""

# Export for current session
export BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"
export BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"

# Offer to save to shell config
echo ""
echo -n "Save to ~/.zshrc for future sessions? (y/n): "
read SAVE_CHOICE

if [ "$SAVE_CHOICE" = "y" ] || [ "$SAVE_CHOICE" = "Y" ]; then
    # Check if already exists
    if grep -q "BROWSERSTACK_USERNAME" ~/.zshrc; then
        echo "⚠️  BrowserStack credentials already in ~/.zshrc"
        echo "   Update them manually if needed"
    else
        echo "" >> ~/.zshrc
        echo "# BrowserStack credentials" >> ~/.zshrc
        echo "export BROWSERSTACK_USERNAME=\"$BROWSERSTACK_USERNAME\"" >> ~/.zshrc
        echo "export BROWSERSTACK_ACCESS_KEY=\"$BROWSERSTACK_ACCESS_KEY\"" >> ~/.zshrc
        echo "✅ Credentials saved to ~/.zshrc"
    fi
fi

echo ""
echo "✅ Credentials set for this session!"
echo ""
echo "Test them with:"
echo "  echo \$BROWSERSTACK_USERNAME"
echo ""

