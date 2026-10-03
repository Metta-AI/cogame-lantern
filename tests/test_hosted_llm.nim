## Retired provider credentials must never activate production inference.
include "../src/lantern/llm"

block:
  delEnv("COWORLD_LLM_ENDPOINT")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "retired-fixture-secret")
  putEnv("ANTHROPIC_API_KEY", "retired-fixture-secret")
  doAssert newLlmClient().disabled
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  doAssert not newLlmClient().disabled
  doAssert newLlmClient().sidecarEndpoint == "http://127.0.0.1:9100"
  echo "Only an explicit native sidecar endpoint activates inference"
