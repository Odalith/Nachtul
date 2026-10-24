#ifndef GSTAUDIO_LIBRARY_H
#define GSTAUDIO_LIBRARY_H
#include <stdbool.h>
#include <stddef.h>
#include <glib.h>
#include <gst/gst.h>
#include <gst/play/play.h>

#ifdef _WIN32
    #define DLL_EXPORT __declspec(dllexport)
#else
    #define DLL_EXPORT __attribute__((visibility("default")))
#endif

typedef void (*NotifyOfError)(const char* message, int request);
typedef void (*VoidType)();
typedef char* (*CharType)();

// Static variables to hold the callback functions
static NotifyOfError notify_of_error_callback = NULL;
static VoidType notify_of_eof_callback = NULL;
static VoidType notify_of_restart_callback = NULL;
static CharType request_next_track_callback = NULL;


DLL_EXPORT void shutdown();

DLL_EXPORT int initialize(const char* app_name, const int initial_volume, const int loop_count, const NotifyOfError callback, const VoidType callback2, const VoidType callback3, const CharType callback4);

DLL_EXPORT void play_audio(const char *filename);

DLL_EXPORT void pause(const bool value);

DLL_EXPORT void seek(const double percentPos);

DLL_EXPORT void set_volume(const int volume);

DLL_EXPORT void mute(const bool value);

DLL_EXPORT void set_loop_count(const int loop_count);

//DLL_EXPORT void wait_loop();

#endif // GSTAUDIO_LIBRARY_H