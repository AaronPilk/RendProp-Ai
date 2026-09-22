// Keep the actual transport/recovery HTTP gates in the existing hosted Deno
// job. Imports are synthetic fixtures only; never native Worker bindings.
import "../../../../tools/audit/uploads_transport_test.ts";
import "../../../edge/upload-gateway/handler.test.ts";
import "../../../edge/upload-gateway/rpc.test.ts";
