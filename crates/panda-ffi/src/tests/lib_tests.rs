    use super::*;

    #[test]
    fn normal_shell_end_has_a_structured_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellSessionClosed),
            PandaError::ShellSessionClosed
        ));
    }

    #[test]
    fn shell_input_backpressure_has_a_structured_ffi_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellInputBackpressure),
            PandaError::ShellInputBackpressure
        ));
    }

    #[test]
    fn shell_nonzero_exit_has_a_structured_ffi_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellExitStatus(7)),
            PandaError::ShellExitStatus(7)
        ));
    }

    #[test]
    fn maps_missing_private_key_passphrase_to_structured_ffi_error() {
        let error = PandaError::from(panda_core::Error::MissingPassphrase);
        assert!(matches!(error, PandaError::MissingPassphrase(_)));
    }

    #[test]
    fn missing_password_stays_distinct_from_authentication_failure() {
        let cfg = HostConfig {
            id: "id".into(),
            name: "host".into(),
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        };
        assert!(matches!(
            ffi_store::credentials_for(&cfg, None, None),
            Err(PandaError::MissingPassword(_))
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::AuthFailed),
            PandaError::AuthFailed
        ));
    }

    #[test]
    fn credential_file_errors_map_to_structured_ffi_errors() {
        assert!(matches!(
            PandaError::from(panda_core::Error::CredentialProtectionKeyRequired),
            PandaError::CredentialProtectionKeyRequired
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::InvalidCredentialFile),
            PandaError::InvalidCredentialFile
        ));
    }

    #[test]
    fn host_key_errors_preserve_structured_fields() {
        let mismatch = PandaError::from(panda_core::Error::HostKeyMismatch {
            host: "host".into(),
            stored_fingerprint: "stored".into(),
            presented_fingerprint: "presented".into(),
        });
        assert!(matches!(
            mismatch,
            PandaError::HostKeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
            } if stored_fingerprint == "stored" && presented_fingerprint == "presented"
        ));

        let unknown = PandaError::from(panda_core::Error::UnknownHostKey {
            host: "host".into(),
            presented: "ssh-ed25519 key".into(),
            fingerprint: "SHA256:fingerprint".into(),
        });
        assert!(matches!(
            unknown,
            PandaError::UnknownHostKey {
                host,
                presented,
                fingerprint,
            } if host == "host" && presented == "ssh-ed25519 key" && fingerprint == "SHA256:fingerprint"
        ));
    }

    #[test]
    fn maps_remaining_structured_core_errors_and_fallbacks() {
        assert!(matches!(
            PandaError::from(panda_core::Error::Timeout),
            PandaError::Timeout
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::Cancelled),
            PandaError::Cancelled
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::CredentialUnlockFailed),
            PandaError::CredentialUnlockFailed
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::UnknownConnection(42)),
            PandaError::UnknownConnection(42)
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::Other("fallback".into())),
            PandaError::Core(message) if message == "fallback"
        ));
        assert!(matches!(
            PandaError::from(std::io::Error::other("io fallback")),
            PandaError::Core(message) if message == "io fallback"
        ));
    }

    #[test]
    fn auth_and_host_records_round_trip_for_password_and_public_key() {
        let password = AuthMethodEnum::Password {
            password_ref: Some("credential.ref".into()),
        };
        assert!(matches!(
            AuthMethodEnum::from(AuthMethod::from(password)),
            AuthMethodEnum::Password { password_ref } if password_ref.as_deref() == Some("credential.ref")
        ));

        let key = AuthMethodEnum::PublicKey {
            key_path: "/tmp/id_ed25519".into(),
            passphrase_ref: None,
        };
        assert!(matches!(
            AuthMethodEnum::from(AuthMethod::from(key)),
            AuthMethodEnum::PublicKey { key_path, passphrase_ref }
                if key_path == "/tmp/id_ed25519" && passphrase_ref.is_none()
        ));

        let record = HostConfigRecord {
            id: "id".into(),
            name: "名称".into(),
            host: "example.com".into(),
            port: 2222,
            username: "user".into(),
            auth: AuthMethodEnum::Password { password_ref: None },
            notes: Some("备注".into()),
            group_id: Some("group".into()),
        };
        let round_trip = HostConfigRecord::from(HostConfig::from(record));
        assert_eq!(round_trip.id, "id");
        assert_eq!(round_trip.port, 2222);
        assert_eq!(round_trip.notes.as_deref(), Some("备注"));
        assert_eq!(round_trip.group_id.as_deref(), Some("group"));
    }

    #[test]
    fn conflict_record_copies_optional_metadata() {
        let record = RemoteFileConflictRecord::from(panda_core::FileConflictInfo {
            source_size: 1,
            source_mtime: Some(2),
            target_size: 3,
            target_mtime: None,
        });
        assert_eq!(record.source_size, 1);
        assert_eq!(record.source_mtime, Some(2));
        assert_eq!(record.target_size, 3);
        assert_eq!(record.target_mtime, None);
    }

    #[test]
    fn every_ffi_error_variant_formats_without_losing_its_payload() {
        let errors = vec![
            PandaError::AuthFailed,
            PandaError::Timeout,
            PandaError::HostKeyMismatch {
                stored_fingerprint: "a".into(),
                presented_fingerprint: "b".into(),
            },
            PandaError::UnknownHostKey {
                host: "h".into(),
                presented: "k".into(),
                fingerprint: "f".into(),
            },
            PandaError::NotInitialized,
            PandaError::UnknownHost("host".into()),
            PandaError::MissingPassword("host".into()),
            PandaError::MissingPassphrase("host".into()),
            PandaError::UnknownShellHandle(1),
            PandaError::ShellSessionClosed,
            PandaError::ShellInputBackpressure,
            PandaError::ShellExitStatus(2),
            PandaError::UnknownSftpHandle(3),
            PandaError::Cancelled,
            PandaError::CredentialProtectionKeyRequired,
            PandaError::CredentialUnlockFailed,
            PandaError::InvalidCredentialFile,
            PandaError::UnknownTransferTask("task".into()),
            PandaError::UnknownConnection(4),
            PandaError::Core("core".into()),
        ];
        assert_eq!(errors.len(), 20);
        assert!(errors
            .into_iter()
            .all(|error| !error.to_string().is_empty()));
    }
