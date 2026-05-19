{
  mkFodHashProducer = import ./mk-fod-hash-producer.nix;

  # Returns `ext.stringValue` once the external has been materialized, else
  # `fallback`. Lets a derivation's own `outputHash` reference the external
  # without throwing on first eval (when the external is still pending).
  readyOr = fallback: ext: if ext.ready then ext.stringValue else fallback;
}
