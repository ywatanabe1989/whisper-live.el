;;; -*- lexical-binding: t -*-
;;; Author: 2024-12-07 16:42:18
;;; Time-stamp: <2024-12-08 11:20:11 (ywatanabe)>
;;; File: ./whisper-live/whisper-live.el


;;; whisper-live.el --- Real-time speech transcription using Whisper -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Yusuke Watanabe

;; Author: Yusuke Watanabe <ywatanabe@alumni.u-tokyo.ac.jp>
;; URL: https://github.com/ywatanabe1989/whisper-live.el
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1") (whisper "0.1.0"))
;; Keywords: multimedia, speech recognition, transcription

;;; Commentary:
;;
;; whisper-live.el provides real-time speech transcription using Whisper.
;; It records audio in chunks and transcribes them on the fly.
;;
;; Features:
;; - Real-time audio transcription
;; - LLM-based cleanup of transcriptions (optional)
;; - Customizable chunk duration and buffer settings
;;
;; Usage:
;; M-x whisper-live-run   ; Toggle transcription

;;; Code:

(require 'request)
(require 'whisper)
(require 'cl-lib)

(defcustom whisper-live-chunk-duration 5
  "Duration of each audio chunk in seconds."
  :type 'integer
  :group 'whisper)

(defcustom whisper-live-buffer-name "*Whisper Live*"
  "Name of the buffer where real-time transcription appears."
  :type 'string
  :group 'whisper)

(defvar whisper-live--current-process nil
  "Current recording process.")

(defvar whisper-live--chunks-directory
  (concat temporary-file-directory "whisper-live-chunks/")
  "Directory to store temporary audio chunks.")

(defvar whisper-live--text-queue '()
  "Queue of recent transcriptions.")

(defcustom whisper-live-max-history 10
  "Maximum number of transcription chunks to keep in history."
  :type 'integer
  :group 'whisper)

(defvar whisper-live--target-buffer nil
  "Buffer where transcribed text should be inserted.")

(defvar whisper-live--insert-marker nil
  "Marker for insertion position.")

(defcustom whisper-live-anthropic-key (or (getenv "ANTHROPIC_API_KEY") "")
  "API key for Anthropic Claude. Defaults to ANTHROPIC_API_KEY environment variable."
  :type 'string
  :group 'whisper-live)

(defcustom whisper-live-anthropic-engine (getenv "ANTHROPIC_ENGINE")
  "Model engine for Anthropic Claude."
  :type 'string
  :group 'whisper-live)

(defcustom whisper-live-clean-with-llm nil
  "Whether to clean transcriptions using LLM (AI language model).
When enabled, transcriptions will be post-processed by an LLM to improve accuracy."
  :type 'boolean
  :group 'whisper-live
  :safe #'booleanp)

(defvar whisper-live-llm-prompt
  "Clean up the following raw text transcribed from audio. Fix minor errors to produce natural language output. As long as meaning is remained, you can revise as a English native speaker. Respond with only the corrected text and NEVER INCLUDE YOUR COMMENTS. Now, the raw transcription is as follows: \n"
  "Prompt text used for LLM-based transcription cleanup.")

;; Tag
(defcustom whisper-live-start-tag-base "Whisper"
  "Tag to prepend at start of transcription."
  :type 'string
  :group 'whisper-live)

(defcustom whisper-live-end-tag-base "Whisper"
  "Tag to append at end of transcription."
  :type 'string
  :group 'whisper-live)

(defun whisper-live--get-start-tag ()
  "Get start tag based on LLM setting."
  (let ((tag (concat (if whisper-live-clean-with-llm
                         (concat whisper-live-start-tag-base " + LLM")
                       whisper-live-start-tag-base)
                     " => ")))
    (message "Generated start tag: %s (LLM: %s)" tag whisper-live-clean-with-llm)
    tag))

(defun whisper-live--get-end-tag ()
  "Get end tag based on LLM setting."
  (let ((tag (concat " <= " (if whisper-live-clean-with-llm
                                (concat whisper-live-end-tag-base " + LLM")
                              whisper-live-end-tag-base))))
    (message "Generated end tag: %s (LLM: %s)" tag whisper-live-clean-with-llm)
    tag))

(defvar whisper-live-start-tag (whisper-live--get-start-tag)
  "Tag to prepend at start of transcription.")

(defvar whisper-live-end-tag (whisper-live--get-end-tag)
  "Tag to append at end of transcription.")

(defun whisper-live--update-tags ()
  "Update tags based on current LLM setting."
  (setq whisper-live-start-tag (whisper-live--get-start-tag)
        whisper-live-end-tag (whisper-live--get-end-tag))
  (message "Tags updated - Start: %s, End: %s"
           whisper-live-start-tag
           whisper-live-end-tag))

(add-variable-watcher 'whisper-live-clean-with-llm
                     (lambda (sym newval op where)
                       (message "LLM setting changed to: %s" newval)
                       (whisper-live--update-tags)))

(whisper-live--update-tags)

(defvar whisper--temp-file (make-temp-file (whisper-live--generate-chunk-filename)))

(defun whisper-live--ensure-directory ()
  "Ensure chunks directory exists."
  (unless (file-exists-p whisper-live--chunks-directory)
    (make-directory whisper-live--chunks-directory t)))

(defun whisper-live--generate-chunk-filename ()
  "Generate unique filename for audio chunk."
  (format "%swhisper-chunk-%s.wav"
          whisper-live--chunks-directory
          (format-time-string "%Y%m%d-%H%M%S")))

(defun whisper-live--transcribe-chunk (chunk-file)
  "Transcribe a single CHUNK-FILE."
  (make-process
   :name "whisper-live-transcribing"
   :command (whisper-command chunk-file)
   :buffer (get-buffer-create "*Whisper Live*")
   :sentinel (lambda (_process event)
               (when (string-equal "finished\n" event)
                 (with-current-buffer (get-buffer "*Whisper Live*")
                   (goto-char (point-min))
                   (when (re-search-forward "\n\n \\(.*\\)\n\n" nil t)
                     (let ((text (match-string 1)))
                       (when (and text (marker-buffer whisper-live--insert-marker))
                         (with-current-buffer (marker-buffer whisper-live--insert-marker)
                           (save-excursion
                             (goto-char whisper-live--insert-marker)
                             (insert (whisper-live--clean-transcript text) " ")
                             (set-marker whisper-live--insert-marker (point))))))))
                 (kill-buffer "*Whisper Live*")
                 (delete-file chunk-file)))))

(defun whisper-live--clean-transcript (text)
  "Clean transcript TEXT by removing parenthetical and bracket expressions."
  (when text
    (let ((cleaned (replace-regexp-in-string "\\[.*?\\]\\|([^)]*)" "" text)))
      (string-trim cleaned))))

(defun whisper-live--record-chunk ()
  "Record a single audio chunk."
  (let ((chunk-file (whisper-live--generate-chunk-filename)))
    (setq whisper-live--current-process
          (make-process
           :name "whisper-live-recording"
           :command `("ffmpeg"
                     "-f" ,whisper--ffmpeg-input-format
                     "-i" ,whisper--ffmpeg-input-device
                     "-t" ,(number-to-string whisper-live-chunk-duration)
                     "-ar" "16000"
                     "-y" ,chunk-file)
           :sentinel (lambda (_process event)
                      (when (string-equal "finished\n" event)
                        (whisper-live--transcribe-chunk chunk-file)
                        (whisper-live--record-chunk)))))))

(defun whisper-live-start ()
  "Start real-time transcription."
  (interactive)
  (insert whisper-live-start-tag)
  (setq whisper-live--target-buffer (current-buffer)
        whisper-live--insert-marker (point-marker))
  (whisper-live--ensure-directory)
  (whisper-live--record-chunk)
  (message "Live transcribing..."))

(defun whisper-live-stop ()
  "Stop real-time transcription and optionally clean final text with LLM."
  (interactive)
  (when whisper-live--current-process
    (delete-process whisper-live--current-process)
    (setq whisper-live--current-process nil))
  (when whisper-live--insert-marker
    (let ((buffer (marker-buffer whisper-live--insert-marker)))
      (when buffer
        (with-current-buffer buffer
          (save-excursion
            (goto-char whisper-live--insert-marker)
            (insert whisper-live-end-tag))
          (whisper-live--clean-transcript-after-stop)))))
  (when whisper-live--insert-marker
    (set-marker whisper-live--insert-marker nil))
  (when (file-exists-p whisper-live--chunks-directory)
    (delete-directory whisper-live--chunks-directory t))
  (message "[-] Stopped."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; LLM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun whisper--live-find-tags ()
  "Find start and end positions of transcription tags."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward (regexp-quote whisper-live-start-tag) nil t)
      (let ((start-pos (match-beginning 0)))
        (when (re-search-forward (regexp-quote whisper-live-end-tag) nil t)
          (cons start-pos (match-end 0)))))))

(defun whisper-live-extract--raw-transcription ()
  "Extract text between transcription tags."
  (interactive)
  (when-let ((tags (whisper--live-find-tags)))
    (message "Found tags: %S" tags)
    (let* ((text (buffer-substring-no-properties (car tags) (cdr tags)))
           (cleaned-text (whisper--live-remove-tags text)))
      (message "Extracted text: '%s'" cleaned-text)
      cleaned-text)))
;; (whisper-live-extract--raw-transcription)

(defun whisper--live-remove-tags (text)
  "Remove whisper live tags from TEXT."
  (interactive)
  (when text
    (replace-regexp-in-string (format "%s\\|%s"
                                    (regexp-quote whisper-live-start-tag)
                                    (regexp-quote whisper-live-end-tag))
                            "" text)))

;; (defun whisper-live--clean-raw-transcription-with-llm (raw-transcription)
;;   (condition-case err
;;       (let* ((full-prompt (concat "(Clean and correct the raw text described from audio chunks. If you do not find suitable answer, please just return empty string. NEVER INCLUDE ANY COMMENTS OTHER THAN THE REVISED TRANSCRIPTION): " raw-transcription))
;;              (response (request
;;                        "https://api.anthropic.com/v1/messages"
;;                        :type "POST"
;;                        :headers `(("content-type" . "application/json")
;;                                 ("x-api-key" . ,whisper-live-anthropic-key)
;;                                 ("anthropic-version" . "2023-06-01"))
;;                        :data (json-encode
;;                              `(("model" . ,whisper-live-anthropic-engine)
;;                                ("max_tokens" . 2048)
;;                                ("messages" . [,(list (cons "role" "user")
;;                                                    (cons "content" full-prompt))])))
;;                        :parser 'json-read
;;                        :sync t
;;                        :silent t))
;;              (resp-data (request-response-data response)))
;;         (when resp-data
;;           (alist-get 'text (aref (alist-get 'content resp-data) 0))))
;;     (error
;;      raw-transcription)))


;; (defun whisper-live--clean-raw-transcription-with-llm (raw-transcription)
;;   (condition-case err
;;       (let* ((full-prompt (concat whisper-live-llm-prompt raw-transcription))
;;              (response (request
;;                        "https://api.anthropic.com/v1/messages"
;;                        :type "POST"
;;                        :headers `(("content-type" . "application/json")
;;                                 ("x-api-key" . ,whisper-live-anthropic-key)
;;                                 ("anthropic-version" . "2023-06-01"))
;;                        :data (json-encode
;;                              `(("model" . ,whisper-live-anthropic-engine)
;;                                ("max_tokens" . 2048)
;;                                ("messages" . [,(list (cons "role" "user")
;;                                                    (cons "content" full-prompt))])))
;;                        :parser 'json-read
;;                        :sync t
;;                        :silent t))
;;              (resp-data (request-response-data response)))
;;         (when resp-data
;;           (alist-get 'text (aref (alist-get 'content resp-data) 0))))
;;     (error
;;      raw-transcription)))


(defun whisper-live--clean-raw-transcription-with-llm (raw-transcription)
  (if (string-empty-p raw-transcription)
      raw-transcription
    (condition-case err
        (let* ((full-prompt (concat whisper-live-llm-prompt raw-transcription))
               (response (request
                         "https://api.anthropic.com/v1/messages"
                         :type "POST"
                         :headers `(("content-type" . "application/json")
                                  ("x-api-key" . ,whisper-live-anthropic-key)
                                  ("anthropic-version" . "2023-06-01"))
                         :data (json-encode
                               `(("model" . ,whisper-live-anthropic-engine)
                                 ("max_tokens" . 2048)
                                 ("messages" . [,(list (cons "role" "user")
                                                     (cons "content" full-prompt))])))
                         :parser 'json-read
                         :sync t
                         :silent t))
               (resp-data (request-response-data response)))
          (when resp-data
            (alist-get 'text (aref (alist-get 'content resp-data) 0))))
      (error
       raw-transcription))))

(defun whisper-live-overwrite--raw-transcription (new-text)
  "Replace text between transcription tags with NEW-TEXT."
  (when-let ((tags (whisper--live-find-tags)))
    (delete-region (car tags) (cdr tags))
    (goto-char (car tags))
    (insert new-text)))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;###autoload
(defun whisper-live-run ()
  "Toggle real-time audio transcription.
If transcription is running, stops it.
If not running, starts new transcription session."
  (interactive)
  (whisper-live--update-tags)
  (if whisper-live--current-process
      (whisper-live-stop)
    (if whisper-install-whispercpp
        (progn
          (whisper--check-model-consistency)
          (whisper-live-start))
      (let ((command (car (whisper-command whisper--temp-file))))
        (if (or (file-exists-p command)
                (executable-find command))
            (whisper-live-start)
          (error (format "Couldn't find %s in PATH, nor is it a file" command)))))))

(defun whisper-live--clean-transcript-after-stop ()
  "Clean transcript after stopping recording."
  (let ((raw-text (whisper-live-extract--raw-transcription)))
    (when raw-text
      (let ((final-text (if whisper-live-clean-with-llm
                           (whisper-live--clean-raw-transcription-with-llm raw-text)
                           raw-text)))
        (when final-text
          (whisper-live-overwrite--raw-transcription final-text))))))

(defun whisper-live--cleanup ()
  "Clean up all whisper-live resources."
  (interactive)
  (when whisper-live--current-process
    (ignore-errors (delete-process whisper-live--current-process)))
  (setq whisper-live--current-process nil)
  (when whisper-live--insert-marker
    (set-marker whisper-live--insert-marker nil))
  (setq whisper-live--text-queue nil
        whisper-live--target-buffer nil)
  (when (file-exists-p whisper-live--chunks-directory)
    (ignore-errors (delete-directory whisper-live--chunks-directory t))))

;; Add to keyboard quit hook
(add-hook 'keyboard-quit-hook #'whisper-live--cleanup)

(provide 'whisper-live)

;;; whisper-live.el ends here

(message "%s was loaded." (file-name-nondirectory (or load-file-name buffer-file-name)))
