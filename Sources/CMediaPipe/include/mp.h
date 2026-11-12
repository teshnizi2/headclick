// Plain-C mirror of MediaPipe Tasks C API v1.2.3 (face landmarker subset).
#include <stdint.h>
#include <stdbool.h>

typedef int MpStatus;
struct MpBaseOptions {
  const char* model_asset_buffer;
  unsigned int model_asset_buffer_count;
  const char* model_asset_path;
  int file_descriptor;
  int delegate;
  int host_environment;
  int host_system;
  const char* host_version;
  const char* ca_bundle_path;
  const char* app_id;
  const char* app_version;
  const char* npu_dispatch_library_dir;
};
struct MpCategory { int index; float score; char* category_name; char* display_name; };
struct MpCategories { struct MpCategory* categories; uint32_t categories_count; };
struct MpNormalizedLandmark { float x, y, z; bool has_visibility; float visibility; bool has_presence; float presence; char* name; };
struct MpNormalizedLandmarks { struct MpNormalizedLandmark* landmarks; uint32_t landmarks_count; };
struct MpMatrix { uint32_t rows; uint32_t cols; float* data; };
typedef struct MpFaceLandmarkerResult {
  struct MpNormalizedLandmarks* face_landmarks; uint32_t face_landmarks_count;
  struct MpCategories* face_blendshapes; uint32_t face_blendshapes_count;
  struct MpMatrix* facial_transformation_matrixes; uint32_t facial_transformation_matrixes_count;
} MpFaceLandmarkerResult;
typedef void* MpImagePtr;
typedef void* MpFaceLandmarkerPtr;
struct MpFaceLandmarkerOptions {
  struct MpBaseOptions base_options;
  int running_mode;
  int num_faces;
  float min_face_detection_confidence;
  float min_face_presence_confidence;
  float min_tracking_confidence;
  bool output_face_blendshapes;
  bool output_facial_transformation_matrixes;
  void* result_callback;
};
MpStatus MpFaceLandmarkerCreate(struct MpFaceLandmarkerOptions* options, MpFaceLandmarkerPtr* out, char** error_msg);
MpStatus MpFaceLandmarkerDetectForVideo(MpFaceLandmarkerPtr l, MpImagePtr image, const void* opts, int64_t ts, MpFaceLandmarkerResult* result, char** error_msg);
void MpFaceLandmarkerCloseResult(MpFaceLandmarkerResult* result);
MpStatus MpImageCreateFromFile(const char* file_name, MpImagePtr* out, char** error_msg);
MpStatus MpImageCreateFromUint8Data(int format, int width, int height, const uint8_t* pixel_data, int pixel_data_size, MpImagePtr* out, char** error_msg);
void MpImageFree(MpImagePtr image);
MpStatus MpFaceLandmarkerClose(MpFaceLandmarkerPtr l, char** error_msg);
