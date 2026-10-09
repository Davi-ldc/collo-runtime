// Stores and reads the Web API objects that installation creates in a realm's ColloRealm::webapi_cache. Runs on the VM
// thread with the JSC API lock held.
//
// Every entry is a JSC::Strong on the realm, rooted for the VM's lifetime and cleared by destroyVmContents. A global
// reads and writes only its own realm's cache, so an object a host function builds always takes its prototype from
// the realm it was called in. A generated getter aborts on an entry that was never stored, since its callers use the
// result as a live cell.

#include "jsc/runtime/state.h"

namespace Collo {

void GlobalObject::cacheURLApi(JSC::JSObject* url_constructor, JSC::JSObject* url_prototype,
    JSC::Structure* url_structure, JSC::JSObject* url_search_params_constructor,
    JSC::JSObject* url_search_params_prototype, JSC::Structure* url_search_params_structure,
    JSC::JSObject* url_search_params_iterator_prototype, JSC::Structure* url_search_params_iterator_structure)
{
    auto& cache = webApiCache();
    cache.url_constructor.set(vm(), url_constructor);
    cache.url_prototype.set(vm(), url_prototype);
    cache.url_structure.set(vm(), url_structure);
    cache.url_search_params_constructor.set(vm(), url_search_params_constructor);
    cache.url_search_params_prototype.set(vm(), url_search_params_prototype);
    cache.url_search_params_structure.set(vm(), url_search_params_structure);
    cache.url_search_params_iterator_prototype.set(vm(), url_search_params_iterator_prototype);
    cache.url_search_params_iterator_structure.set(vm(), url_search_params_iterator_structure);
}

void GlobalObject::cacheHeadersApi(JSC::JSObject* headers_constructor, JSC::JSObject* headers_prototype,
    JSC::Structure* headers_structure, JSC::JSObject* headers_iterator_prototype,
    JSC::Structure* headers_iterator_structure)
{
    auto& cache = webApiCache();
    cache.headers_constructor.set(vm(), headers_constructor);
    cache.headers_prototype.set(vm(), headers_prototype);
    cache.headers_structure.set(vm(), headers_structure);
    cache.headers_iterator_prototype.set(vm(), headers_iterator_prototype);
    cache.headers_iterator_structure.set(vm(), headers_iterator_structure);
}

void GlobalObject::cacheRequestApi(
    JSC::JSObject* request_constructor, JSC::JSObject* request_prototype, JSC::Structure* request_structure)
{
    auto& cache = webApiCache();
    cache.request_constructor.set(vm(), request_constructor);
    cache.request_prototype.set(vm(), request_prototype);
    cache.request_structure.set(vm(), request_structure);
}

void GlobalObject::cacheResponseApi(
    JSC::JSObject* response_constructor, JSC::JSObject* response_prototype, JSC::Structure* response_structure)
{
    auto& cache = webApiCache();
    cache.response_constructor.set(vm(), response_constructor);
    cache.response_prototype.set(vm(), response_prototype);
    cache.response_structure.set(vm(), response_structure);
}

void GlobalObject::cacheReadableStreamApi(JSC::JSObject* readable_stream_constructor,
    JSC::JSObject* readable_stream_prototype, JSC::Structure* readable_stream_structure,
    JSC::JSObject* readable_stream_default_reader_constructor, JSC::JSObject* readable_stream_default_reader_prototype,
    JSC::Structure* readable_stream_default_reader_structure,
    JSC::JSObject* readable_stream_default_controller_constructor,
    JSC::JSObject* readable_stream_default_controller_prototype,
    JSC::Structure* readable_stream_default_controller_structure,
    JSC::JSObject* readable_stream_byob_reader_constructor, JSC::JSObject* readable_stream_byob_reader_prototype,
    JSC::Structure* readable_stream_byob_reader_structure, JSC::JSObject* readable_stream_byob_request_constructor,
    JSC::JSObject* readable_stream_byob_request_prototype, JSC::Structure* readable_stream_byob_request_structure,
    JSC::JSObject* readable_byte_stream_controller_constructor,
    JSC::JSObject* readable_byte_stream_controller_prototype, JSC::Structure* readable_byte_stream_controller_structure,
    JSC::JSObject* readable_stream_async_iterator_prototype, JSC::Structure* readable_stream_async_iterator_structure)
{
    auto& cache = webApiCache();
    cache.readable_stream_constructor.set(vm(), readable_stream_constructor);
    cache.readable_stream_prototype.set(vm(), readable_stream_prototype);
    cache.readable_stream_structure.set(vm(), readable_stream_structure);
    cache.readable_stream_default_reader_constructor.set(vm(), readable_stream_default_reader_constructor);
    cache.readable_stream_default_reader_prototype.set(vm(), readable_stream_default_reader_prototype);
    cache.readable_stream_default_reader_structure.set(vm(), readable_stream_default_reader_structure);
    cache.readable_stream_default_controller_constructor.set(vm(), readable_stream_default_controller_constructor);
    cache.readable_stream_default_controller_prototype.set(vm(), readable_stream_default_controller_prototype);
    cache.readable_stream_default_controller_structure.set(vm(), readable_stream_default_controller_structure);
    cache.readable_stream_byob_reader_constructor.set(vm(), readable_stream_byob_reader_constructor);
    cache.readable_stream_byob_reader_prototype.set(vm(), readable_stream_byob_reader_prototype);
    cache.readable_stream_byob_reader_structure.set(vm(), readable_stream_byob_reader_structure);
    cache.readable_stream_byob_request_constructor.set(vm(), readable_stream_byob_request_constructor);
    cache.readable_stream_byob_request_prototype.set(vm(), readable_stream_byob_request_prototype);
    cache.readable_stream_byob_request_structure.set(vm(), readable_stream_byob_request_structure);
    cache.readable_byte_stream_controller_constructor.set(vm(), readable_byte_stream_controller_constructor);
    cache.readable_byte_stream_controller_prototype.set(vm(), readable_byte_stream_controller_prototype);
    cache.readable_byte_stream_controller_structure.set(vm(), readable_byte_stream_controller_structure);
    cache.readable_stream_async_iterator_prototype.set(vm(), readable_stream_async_iterator_prototype);
    cache.readable_stream_async_iterator_structure.set(vm(), readable_stream_async_iterator_structure);
}

void GlobalObject::cacheWritableStreamApi(JSC::JSObject* writable_stream_constructor,
    JSC::JSObject* writable_stream_prototype, JSC::Structure* writable_stream_structure,
    JSC::JSObject* writable_stream_default_writer_constructor, JSC::JSObject* writable_stream_default_writer_prototype,
    JSC::Structure* writable_stream_default_writer_structure,
    JSC::JSObject* writable_stream_default_controller_constructor,
    JSC::JSObject* writable_stream_default_controller_prototype,
    JSC::Structure* writable_stream_default_controller_structure)
{
    auto& cache = webApiCache();
    cache.writable_stream_constructor.set(vm(), writable_stream_constructor);
    cache.writable_stream_prototype.set(vm(), writable_stream_prototype);
    cache.writable_stream_structure.set(vm(), writable_stream_structure);
    cache.writable_stream_default_writer_constructor.set(vm(), writable_stream_default_writer_constructor);
    cache.writable_stream_default_writer_prototype.set(vm(), writable_stream_default_writer_prototype);
    cache.writable_stream_default_writer_structure.set(vm(), writable_stream_default_writer_structure);
    cache.writable_stream_default_controller_constructor.set(vm(), writable_stream_default_controller_constructor);
    cache.writable_stream_default_controller_prototype.set(vm(), writable_stream_default_controller_prototype);
    cache.writable_stream_default_controller_structure.set(vm(), writable_stream_default_controller_structure);
}

void GlobalObject::cacheTransformStreamApi(JSC::JSObject* transform_stream_constructor,
    JSC::JSObject* transform_stream_prototype, JSC::Structure* transform_stream_structure,
    JSC::JSObject* transform_stream_default_controller_constructor,
    JSC::JSObject* transform_stream_default_controller_prototype,
    JSC::Structure* transform_stream_default_controller_structure)
{
    auto& cache = webApiCache();
    cache.transform_stream_constructor.set(vm(), transform_stream_constructor);
    cache.transform_stream_prototype.set(vm(), transform_stream_prototype);
    cache.transform_stream_structure.set(vm(), transform_stream_structure);
    cache.transform_stream_default_controller_constructor.set(vm(), transform_stream_default_controller_constructor);
    cache.transform_stream_default_controller_prototype.set(vm(), transform_stream_default_controller_prototype);
    cache.transform_stream_default_controller_structure.set(vm(), transform_stream_default_controller_structure);
}

void GlobalObject::cacheDOMExceptionApi(JSC::JSObject* dom_exception_constructor,
    JSC::JSObject* dom_exception_prototype, JSC::Structure* dom_exception_structure)
{
    auto& cache = webApiCache();
    cache.dom_exception_constructor.set(vm(), dom_exception_constructor);
    cache.dom_exception_prototype.set(vm(), dom_exception_prototype);
    cache.dom_exception_structure.set(vm(), dom_exception_structure);
}

void GlobalObject::cacheEventApi(JSC::JSObject* event_constructor, JSC::JSObject* event_prototype,
    JSC::Structure* event_structure, JSC::JSObject* custom_event_constructor, JSC::JSObject* custom_event_prototype,
    JSC::Structure* custom_event_structure, JSC::JSObject* message_event_constructor,
    JSC::JSObject* message_event_prototype, JSC::Structure* message_event_structure,
    JSC::JSObject* error_event_constructor, JSC::JSObject* error_event_prototype, JSC::Structure* error_event_structure,
    JSC::JSObject* close_event_constructor, JSC::JSObject* close_event_prototype, JSC::Structure* close_event_structure,
    JSC::JSObject* event_target_constructor, JSC::JSObject* event_target_prototype,
    JSC::Structure* event_target_structure)
{
    auto& cache = webApiCache();
    cache.event_constructor.set(vm(), event_constructor);
    cache.event_prototype.set(vm(), event_prototype);
    cache.event_structure.set(vm(), event_structure);
    cache.custom_event_constructor.set(vm(), custom_event_constructor);
    cache.custom_event_prototype.set(vm(), custom_event_prototype);
    cache.custom_event_structure.set(vm(), custom_event_structure);
    cache.message_event_constructor.set(vm(), message_event_constructor);
    cache.message_event_prototype.set(vm(), message_event_prototype);
    cache.message_event_structure.set(vm(), message_event_structure);
    cache.error_event_constructor.set(vm(), error_event_constructor);
    cache.error_event_prototype.set(vm(), error_event_prototype);
    cache.error_event_structure.set(vm(), error_event_structure);
    cache.close_event_constructor.set(vm(), close_event_constructor);
    cache.close_event_prototype.set(vm(), close_event_prototype);
    cache.close_event_structure.set(vm(), close_event_structure);
    cache.event_target_constructor.set(vm(), event_target_constructor);
    cache.event_target_prototype.set(vm(), event_target_prototype);
    cache.event_target_structure.set(vm(), event_target_structure);
}

void GlobalObject::cacheAbortApi(JSC::JSObject* abort_controller_constructor, JSC::JSObject* abort_controller_prototype,
    JSC::Structure* abort_controller_structure, JSC::JSObject* abort_signal_constructor,
    JSC::JSObject* abort_signal_prototype, JSC::Structure* abort_signal_structure)
{
    auto& cache = webApiCache();
    cache.abort_controller_constructor.set(vm(), abort_controller_constructor);
    cache.abort_controller_prototype.set(vm(), abort_controller_prototype);
    cache.abort_controller_structure.set(vm(), abort_controller_structure);
    cache.abort_signal_constructor.set(vm(), abort_signal_constructor);
    cache.abort_signal_prototype.set(vm(), abort_signal_prototype);
    cache.abort_signal_structure.set(vm(), abort_signal_structure);
}

void GlobalObject::cacheTextCodecApi(JSC::JSObject* text_encoder_constructor, JSC::JSObject* text_encoder_prototype,
    JSC::Structure* text_encoder_structure, JSC::JSObject* text_decoder_constructor,
    JSC::JSObject* text_decoder_prototype, JSC::Structure* text_decoder_structure,
    JSC::JSObject* text_encoder_stream_constructor, JSC::JSObject* text_encoder_stream_prototype,
    JSC::Structure* text_encoder_stream_structure, JSC::JSObject* text_decoder_stream_constructor,
    JSC::JSObject* text_decoder_stream_prototype, JSC::Structure* text_decoder_stream_structure)
{
    auto& cache = webApiCache();
    cache.text_encoder_constructor.set(vm(), text_encoder_constructor);
    cache.text_encoder_prototype.set(vm(), text_encoder_prototype);
    cache.text_encoder_structure.set(vm(), text_encoder_structure);
    cache.text_decoder_constructor.set(vm(), text_decoder_constructor);
    cache.text_decoder_prototype.set(vm(), text_decoder_prototype);
    cache.text_decoder_structure.set(vm(), text_decoder_structure);
    cache.text_encoder_stream_constructor.set(vm(), text_encoder_stream_constructor);
    cache.text_encoder_stream_prototype.set(vm(), text_encoder_stream_prototype);
    cache.text_encoder_stream_structure.set(vm(), text_encoder_stream_structure);
    cache.text_decoder_stream_constructor.set(vm(), text_decoder_stream_constructor);
    cache.text_decoder_stream_prototype.set(vm(), text_decoder_stream_prototype);
    cache.text_decoder_stream_structure.set(vm(), text_decoder_stream_structure);
}

void GlobalObject::cacheBlobApi(
    JSC::JSObject* blob_constructor, JSC::JSObject* blob_prototype, JSC::Structure* blob_structure)
{
    auto& cache = webApiCache();
    cache.blob_constructor.set(vm(), blob_constructor);
    cache.blob_prototype.set(vm(), blob_prototype);
    cache.blob_structure.set(vm(), blob_structure);
}

void GlobalObject::cacheFileApi(
    JSC::JSObject* file_constructor, JSC::JSObject* file_prototype, JSC::Structure* file_structure)
{
    auto& cache = webApiCache();
    cache.file_constructor.set(vm(), file_constructor);
    cache.file_prototype.set(vm(), file_prototype);
    cache.file_structure.set(vm(), file_structure);
}

void GlobalObject::cacheFormDataApi(JSC::JSObject* form_data_constructor, JSC::JSObject* form_data_prototype,
    JSC::Structure* form_data_structure, JSC::JSObject* form_data_iterator_prototype,
    JSC::Structure* form_data_iterator_structure)
{
    auto& cache = webApiCache();
    cache.form_data_constructor.set(vm(), form_data_constructor);
    cache.form_data_prototype.set(vm(), form_data_prototype);
    cache.form_data_structure.set(vm(), form_data_structure);
    cache.form_data_iterator_prototype.set(vm(), form_data_iterator_prototype);
    cache.form_data_iterator_structure.set(vm(), form_data_iterator_structure);
}

void GlobalObject::cacheCryptoApi(JSC::JSObject* subtle_crypto_constructor, JSC::JSObject* subtle_crypto_prototype,
    JSC::Structure* subtle_crypto_structure, JSC::JSObject* crypto_key_constructor, JSC::JSObject* crypto_key_prototype,
    JSC::Structure* crypto_key_structure)
{
    auto& cache = webApiCache();
    cache.subtle_crypto_constructor.set(vm(), subtle_crypto_constructor);
    cache.subtle_crypto_prototype.set(vm(), subtle_crypto_prototype);
    cache.subtle_crypto_structure.set(vm(), subtle_crypto_structure);
    cache.crypto_key_constructor.set(vm(), crypto_key_constructor);
    cache.crypto_key_prototype.set(vm(), crypto_key_prototype);
    cache.crypto_key_structure.set(vm(), crypto_key_structure);
}

#define COLLO_WEBAPI_CACHE_GETTER(name, field, type)                                                                   \
    type* GlobalObject::name() const                                                                                   \
    {                                                                                                                  \
        auto* value = webApiCache().field.get();                                                                       \
        RELEASE_ASSERT(value);                                                                                         \
        return value;                                                                                                  \
    }
#define COLLO_WEBAPI_CACHE_FIELD(field, type)
#include "webapi_cache.def"
#undef COLLO_WEBAPI_CACHE_GETTER
#undef COLLO_WEBAPI_CACHE_FIELD

} // namespace Collo

void ColloWebApiCache::clear()
{
#define COLLO_WEBAPI_CACHE_GETTER(name, field, type) field.clear();
#define COLLO_WEBAPI_CACHE_FIELD(field, type) field.clear();
#include "webapi_cache.def"
#undef COLLO_WEBAPI_CACHE_GETTER
#undef COLLO_WEBAPI_CACHE_FIELD
    readable_stream_identifier = {};
    readable_stream_owner_identifier = {};
    readable_stream_iterator_identifier = {};
    readable_stream_iterator_return_value_identifier = {};
    readable_stream_iterator_return_pending_identifier = {};
    readable_stream_controller_identifier = {};
    readable_stream_tee_state_identifier = {};
    readable_stream_tee_original_identifier = {};
    readable_stream_tee_branch_a_identifier = {};
    readable_stream_tee_branch_b_identifier = {};
    readable_stream_tee_reading_identifier = {};
    readable_stream_tee_fulfilled_identifier = {};
    readable_stream_tee_rejected_identifier = {};
    readable_stream_tee_branch_a_canceled_identifier = {};
    readable_stream_tee_branch_b_canceled_identifier = {};
    readable_stream_tee_branch_a_reason_identifier = {};
    readable_stream_tee_branch_b_reason_identifier = {};
    readable_stream_from_state_identifier = {};
    readable_stream_from_iterator_identifier = {};
    readable_stream_from_next_identifier = {};
    readable_stream_from_is_async_identifier = {};
    readable_stream_from_done_identifier = {};
    readable_stream_from_next_fulfilled_identifier = {};
    readable_stream_from_next_rejected_identifier = {};
    readable_stream_from_value_fulfilled_identifier = {};
    readable_stream_from_value_rejected_identifier = {};
    readable_stream_from_return_fulfilled_identifier = {};
    readable_stream_from_return_rejected_identifier = {};
    writable_stream_identifier = {};
    writable_stream_controller_identifier = {};
    transform_stream_identifier = {};
    pipe_to_state_identifier = {};
    compression_stream_state_identifier = {};
    text_encoder_stream_state_identifier = {};
    text_decoder_stream_state_identifier = {};
    byte_length_identifier = {};
}
