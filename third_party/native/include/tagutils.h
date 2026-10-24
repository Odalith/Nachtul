#include <cstddef>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <filesystem>
#include <fstream>
#include <taglib/fileref.h>
#include <taglib/tag.h>

#ifndef TAGUTILS_LIBRARY_H
#define TAGUTILS_LIBRARY_H

#ifdef _WIN32
    #define DLL_EXPORT __declspec(dllexport)
#else
    #define DLL_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif


    typedef struct {
      char* Album;
      char* Artist;
      char* Genre;
      char* Title;
      unsigned int Track;
      unsigned int Year;
    } BasicData;

    DLL_EXPORT BasicData* GetBasicTags(const char* fileName);

    DLL_EXPORT void FreeBasicTags(BasicData* basicData);

    typedef enum {
        ALBUM,
        ARTIST,
        COMMENT,
        GENRE,
        TITLE,
        TRACK,
        YEAR
    } CommonTags;

    // Return values:
    // 1: Success
    // 0: Empty comment or failure
    // -1: Exception occurred
    //Make sure to free comment pointer with FreeComment()
    DLL_EXPORT char* GetCommon(const char* fileName, const CommonTags tagType);


    DLL_EXPORT void FreeCommon(char* common);

    // Return values:
    // 1: Success
    // 0: Failure
    // -1: Exception occurred
    DLL_EXPORT int SetFileComment(const char* fileName, const char* comment);


    // Structure to represent an image with its data and size
    typedef struct {
        void* data;   // Pointer to the raw image data
        size_t size;  // Size of the image data in bytes
    } ImageData;

    // Function to get embedded image from audio file
    // Returns NULL if no image found or on error
    // Make sure to free returned pointer with FreeImageData()
    DLL_EXPORT ImageData* GetEmbeddedImage(const char* fileName);

    // Function to free the image data
    DLL_EXPORT void FreeImageData(ImageData* imageData);

    // Structure to represent file audio properties
    typedef struct {
        int bitrate;
        int sampleRate;
        int channels;
        int lengthInMilliseconds;

    } AudioData;

    DLL_EXPORT void FreeAudioData(AudioData* audioData);

    DLL_EXPORT AudioData* GetAudioProperties(const char* fileName);

    // Structure to represent all non-complex properties
    typedef struct {
        char* Album;
        char* Artist;
        char* Genre;
        char* Title;
        char* Comment;
        unsigned int Track;
        unsigned int Year;
        int bitrate;
        int sampleRate;
        int channels;
        int lengthInMilliseconds;

    } StandardProperties;

    DLL_EXPORT StandardProperties* GetStandardProperties(const char* fileName);

    DLL_EXPORT void FreeStandardProperties(StandardProperties* standardProperties);


#ifdef __cplusplus
}
#endif

#endif // TAG_LIBRARY_H