# offboarding
Script to automate user account offboarding for service desk technicians:
   1. Disables AD account, resets password, and removes all groups
   2. Blocks O365 account and forces sign out, removes licenses and converts to shared mailbox
   3. Backs up user's groups and distribution lists to Documents and reassigns OneDrive access

This script requries the AzureAD, ExchangeOnline, and SharepointOnline modules