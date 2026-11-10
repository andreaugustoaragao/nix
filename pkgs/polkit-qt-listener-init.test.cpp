// Headless teardown of a listener that never calls registerListener.
// QCoreApplication destroys both objects on the way out. No GUI and no
// authentication registration. The worker does not build this file.

#include <QCoreApplication>

#include <polkitqt1-agent-listener.h>

namespace
{

class NeverRegistered : public PolkitQt1::Agent::Listener
{
public:
    using Listener::Listener;

    void initiateAuthentication(
        const QString &,
        const QString &,
        const QString &,
        const PolkitQt1::Details &,
        const QString &,
        const PolkitQt1::Identity::List &,
        PolkitQt1::Agent::AsyncResult *) override
    {
    }

    bool initiateAuthenticationFinish() override
    {
        return false;
    }

    void cancelAuthentication() override { }
};

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    // Default constructor. Parent destruction is ordinary Qt teardown.
    new NeverRegistered(&app);
    // Second constructor. The null pointer is an absent PolkitAgentListener,
    // not a subject passed into registration.
    new NeverRegistered(static_cast<PolkitAgentListener *>(nullptr), &app);
    return 0;
}
