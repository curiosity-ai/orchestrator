# Orchestrator
Install or upgrade with the install script (it picks the archive for your platform and checks its SHA-256):

    curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/main/install.sh | sh
    irm https://raw.githubusercontent.com/curiosity-ai/orchestrator/main/install.ps1 | iex     # Windows

Self-contained builds: no .NET installation needed. Or extract the archive for your platform and run the server
with the one mandatory setting, the management password:

    tar -xzf curiosity-orchestrator-$(targetVersion)-linux-x64.tar.gz
    cd curiosity-orchestrator-$(targetVersion)-linux-x64
    ORC_ADMIN_PASSWORD='choose-a-password' ./curiosity-orchestrator
