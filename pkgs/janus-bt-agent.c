/* Pairing agent for one address. docs/14, D-0059, T-0013.
 * The code is read from stdin so it is not a process argument.
 * RequestPinCode and RequestPasskey answer with that code.
 * RequestConfirmation accepts only when the shown number is that code.
 * RequestAuthorization and AuthorizeService accept only this address.
 * Any other device is rejected. The process exits when its parent exits.
 */
#define _GNU_SOURCE

#include <ctype.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <dbus/dbus.h>

#define AGENT_PATH "/org/janus/bluetooth/agent"

static char want_mac[18];
static char pin[17];
static int pin_is_num;
static unsigned long pin_num;
static DBusConnection *bus;
static volatile sig_atomic_t stop;
static pid_t parent_pid;

static void on_signal(int signo) {
  (void)signo;
  stop = 1;
}

static int mac_ok(const char *text) {
  size_t i;

  if (strlen(text) != 17) {
    return 0;
  }
  for (i = 0; i < 17; i++) {
    unsigned char c = (unsigned char)text[i];
    if ((i % 3) == 2) {
      if (c != ':') {
        return 0;
      }
    } else if (!isxdigit(c)) {
      return 0;
    }
    want_mac[i] = (char)toupper(c);
  }
  want_mac[17] = '\0';
  return 1;
}

static int read_pin(void) {
  size_t n;
  size_t i;

  if (!fgets(pin, sizeof pin, stdin)) {
    return 0;
  }
  n = strlen(pin);
  if (n > 0 && pin[n - 1] == '\n') {
    pin[--n] = '\0';
  }
  if (n < 1 || n > 16) {
    return 0;
  }
  pin_is_num = 1;
  for (i = 0; i < n; i++) {
    if (!isalnum((unsigned char)pin[i])) {
      return 0;
    }
    if (!isdigit((unsigned char)pin[i])) {
      pin_is_num = 0;
    }
  }
  if (pin_is_num) {
    pin_num = strtoul(pin, NULL, 10);
    if (pin_num > 999999UL) {
      pin_is_num = 0;
    }
  }
  return 1;
}

static int path_is_want(const char *path) {
  const char *slash;
  const char *hex;
  char got[18];
  size_t i;

  slash = strrchr(path, '/');
  if (!slash || strncmp(slash + 1, "dev_", 4) != 0) {
    return 0;
  }
  hex = slash + 5;
  if (strlen(hex) != 17) {
    return 0;
  }
  for (i = 0; i < 17; i++) {
    unsigned char c = (unsigned char)hex[i];
    if ((i % 3) == 2) {
      if (c != '_') {
        return 0;
      }
      got[i] = ':';
    } else if (!isxdigit(c)) {
      return 0;
    } else {
      got[i] = (char)toupper(c);
    }
  }
  got[17] = '\0';
  return strcmp(got, want_mac) == 0;
}

static void send_msg(DBusMessage *msg) {
  if (!msg) {
    return;
  }
  dbus_connection_send(bus, msg, NULL);
  dbus_message_unref(msg);
}

static void reply_ok(DBusMessage *msg) {
  send_msg(dbus_message_new_method_return(msg));
}

static void reply_reject(DBusMessage *msg) {
  send_msg(dbus_message_new_error(msg, "org.bluez.Error.Rejected", "rejected"));
}

static DBusHandlerResult agent_message(DBusConnection *connection, DBusMessage *msg, void *data) {
  const char *iface;
  const char *member;
  const char *path = NULL;
  const char *text = NULL;
  dbus_uint32_t passkey = 0;

  (void)connection;
  (void)data;
  iface = dbus_message_get_interface(msg);
  member = dbus_message_get_member(msg);
  if (!member) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  if (iface && strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 &&
      strcmp(member, "Introspect") == 0) {
    const char *xml =
      "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
      "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">"
      "<node><interface name=\"org.bluez.Agent1\">"
      "<method name=\"Release\"/>"
      "<method name=\"RequestPinCode\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"pincode\" type=\"s\" direction=\"out\"/></method>"
      "<method name=\"DisplayPinCode\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"pincode\" type=\"s\" direction=\"in\"/></method>"
      "<method name=\"RequestPasskey\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"passkey\" type=\"u\" direction=\"out\"/></method>"
      "<method name=\"DisplayPasskey\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"passkey\" type=\"u\" direction=\"in\"/>"
      "<arg name=\"entered\" type=\"q\" direction=\"in\"/></method>"
      "<method name=\"RequestConfirmation\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"passkey\" type=\"u\" direction=\"in\"/></method>"
      "<method name=\"RequestAuthorization\"><arg name=\"device\" type=\"o\" direction=\"in\"/></method>"
      "<method name=\"AuthorizeService\"><arg name=\"device\" type=\"o\" direction=\"in\"/>"
      "<arg name=\"uuid\" type=\"s\" direction=\"in\"/></method>"
      "<method name=\"Cancel\"/>"
      "</interface></node>";
    DBusMessage *reply = dbus_message_new_method_return(msg);
    dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
    send_msg(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (!iface || strcmp(iface, "org.bluez.Agent1") != 0) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  if (strcmp(member, "Release") == 0 || strcmp(member, "Cancel") == 0) {
    reply_ok(msg);
    if (strcmp(member, "Release") == 0) {
      stop = 1;
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "RequestPinCode") == 0) {
    if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID) ||
        !path_is_want(path)) {
      reply_reject(msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    text = pin;
    {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      dbus_message_append_args(reply, DBUS_TYPE_STRING, &text, DBUS_TYPE_INVALID);
      send_msg(reply);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "RequestPasskey") == 0) {
    dbus_uint32_t value;
    if (!pin_is_num ||
        !dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID) ||
        !path_is_want(path)) {
      reply_reject(msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    value = (dbus_uint32_t)pin_num;
    {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      dbus_message_append_args(reply, DBUS_TYPE_UINT32, &value, DBUS_TYPE_INVALID);
      send_msg(reply);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "RequestConfirmation") == 0) {
    if (!pin_is_num ||
        !dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_UINT32, &passkey,
                               DBUS_TYPE_INVALID) ||
        !path_is_want(path) || passkey != (dbus_uint32_t)pin_num) {
      reply_reject(msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    reply_ok(msg);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "RequestAuthorization") == 0) {
    if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID) ||
        !path_is_want(path)) {
      reply_reject(msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    reply_ok(msg);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "AuthorizeService") == 0) {
    if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_STRING, &text,
                               DBUS_TYPE_INVALID) ||
        !path_is_want(path)) {
      reply_reject(msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    reply_ok(msg);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  /* DisplayPinCode and DisplayPasskey would need a screen on the router. */
  reply_reject(msg);
  return DBUS_HANDLER_RESULT_HANDLED;
}

static int manager_call(const char *method, int with_cap) {
  DBusMessage *msg;
  DBusMessage *reply;
  DBusError err;
  const char *path = AGENT_PATH;
  const char *cap = "KeyboardDisplay";

  msg = dbus_message_new_method_call("org.bluez", "/org/bluez", "org.bluez.AgentManager1", method);
  if (!msg) {
    return 0;
  }
  if (with_cap) {
    dbus_message_append_args(msg, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_STRING, &cap,
                             DBUS_TYPE_INVALID);
  } else {
    dbus_message_append_args(msg, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID);
  }
  dbus_error_init(&err);
  reply = dbus_connection_send_with_reply_and_block(bus, msg, 5000, &err);
  dbus_message_unref(msg);
  if (!reply) {
    if (dbus_error_is_set(&err)) {
      fprintf(stderr, "janus-bt-agent: %s\n", err.message);
      dbus_error_free(&err);
    }
    return 0;
  }
  dbus_message_unref(reply);
  return 1;
}

int main(int argc, char **argv) {
  DBusError err;
  DBusObjectPathVTable table;

  if (argc != 2 || !mac_ok(argv[1]) || !read_pin()) {
    fprintf(stderr, "janus-bt-agent: usage is one address and a code on stdin\n");
    return 2;
  }
  parent_pid = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) == 0 && getppid() != parent_pid) {
    return 0;
  }
  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  dbus_threads_init_default();
  dbus_error_init(&err);
  bus = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
  if (!bus) {
    fprintf(stderr, "janus-bt-agent: %s\n", err.message ? err.message : "no system bus");
    dbus_error_free(&err);
    return 1;
  }
  dbus_connection_set_exit_on_disconnect(bus, FALSE);
  memset(&table, 0, sizeof table);
  table.message_function = agent_message;
  if (!dbus_connection_try_register_object_path(bus, AGENT_PATH, &table, NULL, &err)) {
    fprintf(stderr, "janus-bt-agent: %s\n", err.message ? err.message : "register path");
    dbus_error_free(&err);
    return 1;
  }
  if (!manager_call("RegisterAgent", 1) || !manager_call("RequestDefaultAgent", 0)) {
    return 1;
  }
  while (!stop && getppid() == parent_pid && dbus_connection_read_write_dispatch(bus, 500)) {
  }
  manager_call("UnregisterAgent", 0);
  dbus_connection_flush(bus);
  return 0;
}
