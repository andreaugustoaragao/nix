// Exercise the production resolver against a mock logind on a private bus.
// No host Polkit registration, GUI, passwords, or system activation.
#include "src/core/LogindSession.hpp"

#include <QCoreApplication>
#include <QDBusVirtualObject>
#include <QProcess>
#include <iostream>
#include <unistd.h>

class MockLogind : public QDBusVirtualObject {
public:
    explicit MockLogind(QString scenario) : scenario(std::move(scenario)) { }

    QString introspect(const QString &) const override { return {}; }

    bool handleMessage(const QDBusMessage &message, const QDBusConnection &bus) override {
        const auto fail = [&] {
            return bus.send(message.createErrorReply(
                QStringLiteral("org.freedesktop.login1.NoSessionForPID"), QStringLiteral("fixture")));
        };
        if (message.interface() == QStringLiteral("org.freedesktop.login1.Manager") &&
            message.member() == QStringLiteral("GetSessionByPID")) {
            if (message.signature() != QStringLiteral("u") || scenario == QStringLiteral("lookup-error"))
                return fail();
            pid = message.arguments().at(0).toUInt();
            if (scenario == QStringLiteral("lookup-wrong-type"))
                return bus.send(message.createReply(QList<QVariant>{QStringLiteral("not-an-object-path")}));
            return bus.send(message.createReply(QList<QVariant>{QVariant::fromValue(
                QDBusObjectPath(QStringLiteral("/org/freedesktop/login1/session/test")))}));
        }
        if (message.path() == QStringLiteral("/org/freedesktop/login1/session/test") &&
            message.interface() == QStringLiteral("org.freedesktop.DBus.Properties") &&
            message.member() == QStringLiteral("Get")) {
            if (message.arguments() != QList<QVariant>{QStringLiteral("org.freedesktop.login1.Session"),
                                                       QStringLiteral("Id")} ||
                scenario == QStringLiteral("property-error"))
                return fail();
            QVariant id = QString::number(pid);
            if (scenario == QStringLiteral("empty-id")) id = QString();
            if (scenario == QStringLiteral("id-wrong-type")) id = quint32(123);
            if (scenario == QStringLiteral("property-wrong-type"))
                return bus.send(message.createReply(QList<QVariant>{id}));
            return bus.send(message.createReply(QList<QVariant>{QVariant::fromValue(QDBusVariant(id))}));
        }
        return fail();
    }

private:
    QString scenario;
    quint32 pid = 0;
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (app.arguments().size() == 3 && app.arguments().at(1) == QStringLiteral("--serve")) {
        auto bus = QDBusConnection::systemBus();
        MockLogind mock(app.arguments().at(2));
        if (!bus.registerVirtualObject(QStringLiteral("/org/freedesktop/login1"), &mock,
                                       QDBusConnection::SubPath) ||
            !bus.registerService(QStringLiteral("org.freedesktop.login1")))
            return 1;
        std::cout << "READY\n" << std::flush;
        return app.exec();
    }

    // A misleading environment session ID must never rescue a failed lookup.
    qputenv("XDG_SESSION_ID", "untrusted-session");
    if (!logindSessionForProcess(getpid()).isEmpty()) return 2;

    for (const auto &scenario : {"success", "lookup-error", "lookup-wrong-type", "property-error",
                                 "empty-id", "id-wrong-type", "property-wrong-type"}) {
        QProcess server;
        server.start(app.applicationFilePath(), {QStringLiteral("--serve"), QString::fromLatin1(scenario)});
        if (!server.waitForStarted() || !server.waitForReadyRead() || server.readLine() != "READY\n")
            return 3;
        const auto id = logindSessionForProcess(getpid());
        const bool expected = QString::fromLatin1(scenario) == QStringLiteral("success");
        // The mock returns the PID received over D-Bus as Id, proving exact PID targeting.
        const bool ok = expected ? id == QString::number(getpid()) : id.isEmpty();
        server.kill();
        server.waitForFinished();
        if (!ok) {
            std::cerr << "Resolver failed scenario: " << scenario << '\n';
            return 4;
        }
    }
    std::cout << "Logind resolver passed: exact PID, missing service, errors, types, empty ID.\n";
    return 0;
}
