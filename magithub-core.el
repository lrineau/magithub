;;; magithub-core.el --- core functions for magithub  -*- lexical-binding: t; -*-

;; Copyright (C) 2016-2017  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'magit)
(require 'dash)
(require 's)
(require 'subr-x)
(require 'ghub)
(require 'bug-reference)
(require 'cl-lib)

(require 'magithub-faces)

;;; Debugging utilities
(defvar magithub-debug-mode nil
  "Controls what kinds of debugging information shows.
List of symbols.

`dry-api' - don't actually make API requests
`forms' - show forms being evaluated in the cache")

(defun  magithub-debug-mode (&optional submode)
  "True if debug mode is on.
If SUBMODE is supplied, specifically check for that mode in
`magithub-debug-mode'."
  (and (listp magithub-debug-mode)
       (memq submode magithub-debug-mode)))

(defun magithub-debug-message (fmt &rest args)
  "Print a debug message.
Respects `magithub-debug-mode' and `debug-on-error'."
  (when (or magithub-debug-mode debug-on-error)
    (let ((print-quoted t))
      (message "magithub: (%s) %s"
               (format-time-string "%M:%S.%3N" (current-time))
               (apply #'format fmt args)))))

(defun magithub-debug--ghub-request-wrapper (oldfun &rest args)
  "Report ghub requests as they're being made.
Intended as around-advice for `ghub-requst'."
  (magithub-debug-message
   "ghub-request%S" `(,(car args)
                      ,(concat ghub-base-url (cadr args))
                      ,@(cddr args)))
  (unless (magithub-debug-mode 'dry-api)
    (apply oldfun args)))
(advice-add #'ghub-request :around #'magithub-debug--ghub-request-wrapper)

(defcustom magithub-dir
  (expand-file-name "magithub" user-emacs-directory)
  "Data directory.
Various Magithub data (such as the cache) will be dumped into the
root of this directory.

If it does not exist, it will be created."
  :group 'magithub
  :type 'directory)

;;; Turning Magithub on/off
(defun magithub-enable ()
  "Enable Magithub for this repository."
  (interactive)
  (magit-set "true" "magithub" "enabled")
  (magit-refresh)
  (message "Magithub is now enabled in this repository"))

(defmacro magithub-in-data-dir (&rest forms)
  "Execute forms in `magithub-dir'.
If `magithub-dir' does not yet exist, it and its parents will be
created automatically."
  `(progn
     (unless (file-directory-p magithub-dir)
       (mkdir magithub-dir t))
     (let ((default-directory magithub-dir))
       ,@forms)))

(defun magithub-disable ()
  "Disable Magithub for this repository."
  (interactive)
  (magit-set "false" "magithub" "enabled")
  (magit-refresh)
  (message "Magithub is now disabled in this repository"))

(defcustom magithub-enabled-by-default t
  "Non-nil if Magithub is enabled by default."
  :group 'magithub
  :type 'boolean)

(defun magithub-enabled-p ()
  "Returns non-nil when Magithub is enabled for this repository."
  (let ((enabled (magit-get "magithub" "enabled")))
    (cond
     ((member enabled '("yes" "true")) t)
     ((member enabled '("no" "false")) nil)
     (t magithub-enabled-by-default))))

(defun magithub-enabled-toggle ()
  "Toggle Magithub integration."
  (interactive)
  (if (magithub-enabled-p)
      (magithub-disable)
    (magithub-enable)))

;;; Caching; Online/Offline mode
(defvar magithub-cache 'when-present
  "Determines how the cache behaves.

If nil, the cache will not be used to read cached data.  It will
still be updated and written to disk.

If t, *only* the cache will be used.  This constitutes Magithub's
'offline' mode.

If `when-present', we'll use the cached value when present, but
we'll make a request if there's no appropriate value.  (Note that
an API response of nil is considered an appropriate value.)")

(defun magithub-offline-p ()
  "Non-nil if Magithub is not supposed to make API requests."
  (eq magithub-cache t))

(defun magithub-toggle-online ()
  "Toggle online status.
Runs either `magithub-go-online' or `magithub-go-offline'
depending on `magithub-offline-p'."
  (interactive)
  (if (magithub-offline-p)
      (magithub-go-online)
    (magithub-go-offline)))

(defun magithub-go-online ()
  "Take Magithub online.
API requests will be made to refresh expired caches."
  (interactive)
  (setq magithub-cache 'when-present)
  (magit-refresh)
  (message "Magithub is now online everywhere"))

(defun magithub-go-offline ()
  "Take Magithub offline.
No API requests will be made; all information displayed will be
retrieved from the cache."
  (interactive)
  (setq magithub-cache t)
  (magit-refresh)
  (message "Magithub is now offline everywhere"))

(defcustom magithub-cache-file "cache"
  "Use this file for Magithub's persistent cache."
  :group 'magithub
  :type 'file)

(defvar magithub-cache--cache
  (or (ignore-errors
        (magithub-cache-read-from-disk))
      (make-hash-table :test 'equal))
  "The actual cache.
Holds all information ever cached by Magithub.

Occasionally written to `magithub-cache-file' by
`magithub-cache-write-to-disk'.")

(defvar magithub-cache--needs-write nil
  "Signals that the cache has been updated.
When non-nil, the cache will be written to disk next time the
idle timer runs.")

(defun magithub-cache-read-from-disk ()
  "Returns the cache as read from disk `magithub-cache-file'."
  (when (file-readable-p magithub-cache-file)
    (with-temp-buffer
      (insert-file-contents magithub-cache-file)
      (read (current-buffer)))))

(defvar magithub-cache-ignore-class nil
  "Class to ignore in `magithub-cache'.
See also `magithub-cache-without-cache'.")

(cl-defun magithub-cache (class form &key message)
  "The cached value for FORM if available.

If FORM has not been cached or its CLASS dictates the cache has
expired, FORM will be re-evaluated.

CLASS: The kind of data this is; see `magithub-cache-ignore-class'.

MESSAGE may be specified for intensive functions.  We'll display
this with `with-temp-message' while the form is evaluating.

CONTEXT is a symbol specifying the cache context.  If it's the
special symbol `repo' (the default), we'll use the context of the
current repository."
  (declare (indent defun))
  (let ((entry (list (ghubp-get-context) class form))
        (recalc (or (null magithub-cache)
                    (and magithub-cache-ignore-class
                         (eq magithub-cache-ignore-class class))))
        no-value-sym cached-value)
    (unless recalc
      (setq no-value-sym (cl-gensym)
            cached-value (gethash entry magithub-cache--cache no-value-sym)
            recalc (eq cached-value no-value-sym)))

    (let ((v (if recalc
                 (prog1 (puthash entry
                                 (with-temp-message message
                                   (eval form))
                                 magithub-cache--cache)
                   (setq magithub-cache--needs-write t)
                   (run-with-idle-timer 600 nil #'magithub-cache-write-to-disk))
               cached-value)))
      v)))

(defun magithub-cache-invalidate ()
  "Clear the cache from memory."
  (maphash
   (lambda (k _)
     (remhash k magithub-cache--cache))
   magithub-cache--cache))

(defun magithub-maybe-report-offline-mode ()
  "Conditionally inserts the OFFLINE header.
If this is a Magithub-enabled repository and we're offline, we
insert a header notifying the user that all data shown is cached.
To aid in determining if the cache should be refreshed, we report
the age of the oldest cached information."
  (when (and (magithub-usable-p)
             (magithub-offline-p))
    (magit-insert-section (magithub)
      (insert
       (format "Magithub: %s; use %s to refresh GitHub content\n"
               (propertize "OFFLINE" 'face 'magit-head)
               (propertize
                (substitute-command-keys "C-u \\[magit-refresh]")
                'face 'magit-header-line-key))))))

(eval-after-load "magit"
  '(add-hook 'magit-status-headers-hook
             #'magithub-maybe-report-offline-mode
             'append))

(defun magithub-cache--time-out (time)
  "Convert TIME into a human-readable string.

Returns \"Xd Xh Xm Xs\" (counting from zero)"
  (let ((seconds (time-to-seconds time)))
    (format-time-string
     (cond
      ((< seconds 60)              "%-Ss")
      ((< seconds 3600)       "%-Mm %-Ss")
      ((< seconds 86400) "%-Hh %-Mm %-Ss")
      (t            "%-jd %-Hh %-Mm %-Ss"))
     time)))

(defun magithub-cache-write-to-disk ()
  "Write the cache to disk.
The cache is writtin to `magithub-cache-file' in
`magithub-data-dir'"
  (if (active-minibuffer-window)
      (run-with-idle-timer 600 nil #'magithub-cache-write-to-disk) ;defer
    (when magithub-cache--needs-write
      (magithub-in-data-dir
       (with-temp-buffer
         (insert (prin1-to-string magithub-cache--cache))
         (write-file magithub-cache-file)))
      (setq magithub-cache--needs-write nil)
      (magithub-debug-message "wrote cache to disk"))))

(defmacro magithub-cache-without-cache (class &rest body)
  "For CLASS, execute BODY without using CLASS's caches."
  (declare (indent 1))
  `(let ((magithub-cache-ignore-class ,class))
     ,@body))

(add-hook 'kill-emacs-hook
          #'magithub-cache-write-to-disk)

;;; API availability checking
(define-error 'magithub-error "Magithub Error")
(define-error 'magithub-api-timeout "Magithub API Timeout" 'magithub-error)

(defvar magithub--api-last-checked
  ;; see https://travis-ci.org/vermiculus/magithub/jobs/259006323
  ;; (eval-when-compile (date-to-time "1/1/1970"))
  '(14445 17280)
  "The last time the API was available.
Used to avoid pinging GitHub multiple times a second.")

(defcustom magithub-api-timeout 3
  "Number of seconds we'll wait for the API to respond."
  :group 'magithub
  :type 'integer)

(defcustom magithub-api-low-threshold 15
  "Low threshold for API requests.
This variable is not currently respected; see tarsius/ghub#16.

If the number of available API requests drops to or below this
threshold, you'll be asked if you'd like to go offline."
  :group 'magithub
  :type 'integer)

(defcustom magithub-api-available-check-frequency 10
  "Minimum number of seconds between each API availability check.
While online (see `magithub-go-online'), we check to ensure the API is available
before making a real request. This involves a `/rate_limit' call (or for some
Enterprise instances, a `/meta' call). Use this setting to configure how often
this is done. It will be done no more frequently than other API actions.

These calls are guaranteed to not count against your rate limit."
  :group 'magithub
  :type 'integer)

(defvar magithub--quick-abort-api-check nil
  "When non-nil, we'll assume the API is unavailable.
Do not modify this variable in code outside Magithub.")

(defvar magithub--api-offline-reason nil
  "The reason we're going offline.
Could be one of several strings:

 * authentication issue

 * response timeout

 * generic error

and possibly others as error handlers are added to
`magithub--api-available-p'.")

(defun magithub--api-available-p ()
  "Non-nil if the API is available.
Pings the API a maximum of once every ten seconds."
  (when (magithub-enabled-p)
    (unless (magithub-offline-p)
      (magithub-debug-message "checking if the API is available")
      (prog1
          (when
              (condition-case _
                  (progn
                    (magithub-debug-message "making sure authinfo is unlocked")
                    (ghub--token))
                ;; Magithub only works when authenticated.
                (ghub-auth-error
                 (prog1 nil
                   (if (y-or-n-p "Not yet authenticated; open instructions in your browser? ")
                       (progn
                         (browse-url "https://github.com/magit/ghub#initial-configuration")
                         (setq magithub--api-offline-reason "Try again once you've authenticated"))
                     (setq magithub--api-offline-reason "Not yet authenticated per ghub's README")))))
            (if (and magithub--api-last-checked
                     (< (time-to-seconds (time-since magithub--api-last-checked)) magithub-api-available-check-frequency))
                (prog1 magithub--api-last-checked
                  (magithub-debug-message "used cached value for api-last-checked"))

              (magithub-debug-message "cache expired; retrieving new value for api-last-checked")
              (setq magithub--api-last-checked (current-time))

              (let (api-status error-data response)
                (condition-case err
                    (progn
                      (setq response
                            (condition-case _
                                (with-timeout (magithub-api-timeout
                                               (signal 'magithub-api-timeout nil))
                                  (ghub-get "/rate_limit"))

                              (ghub-404
                               ;; Rate-limiting is often disabled on
                               ;; Enterprise instances.  Try using /meta
                               ;; which should (hopefully) always work.  See
                               ;; also issue #107.
                               (ghub-get "/meta")))
                            api-status (and response t))

                      (magithub-debug-message "new value retrieved for api-last-available: %S"
                                              response))

                  ;; Sometimes, the API can take a long time to respond
                  ;; (whether that's GitHub not responding or requests being
                  ;; blocked by some client-side firewal).  Handle this
                  ;; possibility gracefully.
                  (magithub-api-timeout
                   (setq error-data err
                         magithub--api-offline-reason
                         (concat "API is not responding quickly; "
                                 "consider customizing `magithub-api-timeout' if this happens often")))

                  ;; Never hurts to be cautious :-)
                  (error
                   (setq error-data err
                         magithub--api-offline-reason (format "unknown issue: %S" err))))

                (when error-data
                  (magithub-debug-message "consider reporting unknown error while checking api-available: %S"
                                          error-data))

                api-status)))
        (when magithub--api-offline-reason
          (magithub-go-offline)
          (run-with-idle-timer 2 nil #'magithub--api-offline-reason))))))

(defun magithub--api-offline-reason ()
  "Report the reason we're going offline and go offline.
Refresh the status buffer if necessary.

See `magithub--api-offline-reason'."
  (when magithub--api-offline-reason
    (message "Magithub is now offline: %s"
             magithub--api-offline-reason)
    (setq magithub--api-offline-reason nil)
    (magithub-go-offline)))

(defalias 'magithub-api-rate-limit #'ghubp-ratelimit)

;;; Repository parsing
(defun magithub-github-repository-p ()
  "Non-nil if \"origin\" points to GitHub or a whitelisted domain."
  (when-let ((origin (magit-get "remote" "origin" "url")))
    (-some? (lambda (domain) (s-contains? domain origin))
            (cons "github.com" (magit-get-all "hub" "host")))))

(defalias 'magithub--parse-url 'magithub--repo-parse-url)
(make-obsolete 'magithub--parse-url 'magithub--repo-parse-url "0.1.4")
(defun magithub--repo-parse-url (url)
  "Parse URL into its components.
URL may be of several different formats:

- git@github.com:vermiculus/magithub.git
- https://github.com/vermiculus/magithub"
  (and url
       (or (and (string-match
                 ;; git@github.com:vermiculus/magithub.git
                 (rx bol
                     (group (+? any)) ;sshuser -- git
                     "@"
                     (group (+? any)) ;domain  -- github.com
                     ":"
                     (group (+? (| alnum "-" "."))) ;owner.login -- vermiculus
                     "/"
                     (group (+? (| alnum "-" "."))) ;name -- magithub
                     (? ".git")
                     eol)
                 url)
                `((kind . 'ssh)
                  (ssh-user . ,(match-string 1 url))
                  (domain . ,(match-string 2 url))
                  (sparse-repo (owner (login . ,(match-string 3 url)))
                               (name . ,(match-string 4 url)))))
           (and (string-match
                 ;; https://github.com/vermiculus/magithub.git
                 ;; git://github.com/vermiculus/magithub.git
                 ;; ssh://git@github.com/vermiculus/magithub
                 ;; git+ssh://github.com/vermiculus/magithub.git
                 (rx bol
                     (or (seq "http" (? "s"))
                         (seq "ssh")
                         (seq "git" (? "+ssh")))
                     "://"
                     (group (+? any)) ;domain -- github.com
                     "/"
                     (group (+? (| alnum "-" "."))) ;owner.login -- vermiculus
                     "/"
                     (group (+? (| alnum "-" "."))) ;name -- magithub
                     (? ".git")
                     eol)
                 url)
                `((kind . 'http)
                  (domain . ,(match-string 1 url))
                  (sparse-repo (owner (login . ,(match-string 2 url)))
                               (name . ,(match-string 3 url))))))))

(defun magithub--url->repo (url)
  "Tries to parse a remote url into a GitHub repository object"
  (cdr (assq 'sparse-repo (magithub--repo-parse-url url))))

(defun magithub-source--remote ()
  "Tries to determine the correct remote to use for issue-tracking."
  (or (magit-get "magithub" "proxy") "origin"))

(defun magithub-source--sparse-repo ()
  "Returns the sparse repository object for the current context.

Only information that can be determined without API calls will be
included in the returned object."
  (magithub-repo-from-remote--sparse
   (magithub-source--remote)))

(defun magithub-repo-from-remote (remote)
  (magithub-repo (magithub-repo-from-remote--sparse remote)))

(defun magithub-repo-from-remote--sparse (remote)
  (magithub--url->repo (magit-get "remote" remote "url")))

(defalias 'magithub-source-repo 'magithub-repo)
(make-obsolete 'magithub-source-repo 'magithub-repo "0.1.4")
(defun magithub-repo (&optional sparse-repo)
  "Turn SPARSE-REPO into a full repository object.
If SPARSE-REPO is null, the current context is used."
  (let ((sparse-repo (or sparse-repo (magithub-source--sparse-repo))))
    (or (magithub-cache :repo-demographics
          `(condition-case e
               (or (ghubp-get-repos-owner-repo ',sparse-repo)
                   (and (not (magithub--api-available-p))
                        sparse-repo))
             ;; Repo may not exist; ignore 404
             (ghub-404 nil)))
        (when (eq magithub-cache 'when-present)
          (let ((magithub-cache nil))
            (magithub-repo sparse-repo))))))

;;; Repository utilities
(defun magithub-repo-name (repo)
  "Return the full name of REPO.
If the `full_name' object is present, use that.  Otherwise,
concatenate `.owner.login' and `.name' with `/'."
  (let-alist repo
    (if .full_name .full_name
      (concat .owner.login "/" .name))))

(defun magithub--repo-simplify (repo)
  "Convert full repository object REPO to a sparse repository object."
  (let (login name)
    ;; There are syntax problems with things like `,.owner.login'
    (let-alist repo
      (setq login .owner.login
            name .name))
    `((owner (login . ,login))
      (name . ,name))))

(defun magithub-repo-remotes ()
  "Return GitHub repositories in this repository.
`magit-list-remotes' is filtered to those remotes that point to
GitHub repositories."
  (delq nil (mapcar (lambda (r) (cons r (magithub-repo-from-remote r)))
                    (magit-list-remotes))))

(defun magithub-read-repo (prompt)
  "Using PROMPT, read a GitHub repository.
See also `magithub-repo-remotes'."
  (let* ((remotes (magithub-repo-remotes))
         (maxlen (->> remotes
                      (mapcar #'car)
                      (mapcar #'length)
                      (apply #'max)))
         (fmt (format "%%-%ds (%%s/%%s)" maxlen)))
    (magithub-repo
     (cdr (magithub--completing-read
           prompt (magithub-repo-remotes)
           (lambda (remote-repo-pair)
             (let-alist (cdr remote-repo-pair)
               (format fmt (car remote-repo-pair) .owner.login .name))))))))

(defun magithub-repo-remotes-for-repo (repo)
  (-filter (lambda (remote)
             (let-alist (list (cons 'repo repo)
                              (cons 'remote (magithub-repo-from-remote remote)))
               (and (string= .repo.owner.login
                             .remote.owner.login)
                    (string= .repo.name .remote.name))))
           (magit-list-remotes)))

;;; Feature checking
(defconst magithub-feature-list
  '(pull-request-merge pull-request-checkout)
  "All magit-integration features of Magithub.

`pull-request-merge'
Apply patches from pull request

`pull-request-checkout'
Checkout pull requests as new branches")

(defvar magithub-features nil
  "An alist of feature-symbols to Booleans.
When a feature symbol maps to non-nil, that feature is considered
'loaded'.  Thus, to disable all messages, prepend '(t . t) to
this list.

Example:

    ((pull-request-merge . t) (other-feature . nil))

signals that `pull-request-merge' is a loaded feature and
`other-feature' has not been loaded and will not be loaded.

To enable all features, see `magithub-feature-autoinject'.

See `magithub-feature-list' for a list and description of features.")

(defun magithub-feature-check (feature)
  "Check if a Magithub FEATURE has been configured.
See `magithub-features'."
  (if (listp magithub-features)
      (let* ((p (assq feature magithub-features)))
        (if (consp p) (cdr p)
          (cdr (assq t magithub-features))))
    magithub-features))

(defun magithub-feature-maybe-idle-notify (&rest feature-list)
  "Notify user if any of FEATURES are not yet configured."
  (unless (-all? #'magithub-feature-check feature-list)
    (let ((m "Magithub features not configured: %S")
          (s "see variable `magithub-features' to turn off this message"))
      (run-with-idle-timer
       1 nil (lambda ()
               (message (concat m "; " s) feature-list)
               (add-to-list 'feature-list '(t . t) t))))))

;;; Getting help
(defun magithub--meta-new-issue ()
  "Open a new Magithub issue.
See /.github/ISSUE_TEMPLATE.md in this repository."
  (interactive)
  (browse-url "https://github.com/vermiculus/magithub/issues/new"))

(defun magithub--meta-help ()
  "Open Magithub help."
  (interactive)
  (browse-url "https://gitter.im/vermiculus/magithub"))

(defun magithub-error (err-message tag &optional trace)
  "Report a Magithub error."
  (setq trace (or trace (with-output-to-string (backtrace))))
  (when (y-or-n-p (concat tag "  Report?  (A bug report will be placed in your clipboard.)"))
    (with-current-buffer-window
     (get-buffer-create "*magithub issue*")
     #'display-buffer-pop-up-window nil
     (when (fboundp 'markdown-mode) (markdown-mode))
     (insert
      (kill-new
       (format
        "## Automated error report

### Description

%s

### Backtrace

```
%s```
"
        (read-string "Briefly describe what you were doing: ")
        trace))))
    (magithub--meta-new-issue))
  (error err-message))

;;; Miscellaneous utilities

(defun magithub--completing-read (prompt collection &optional format-function predicate require-match default)
  "Using PROMPT, get a list of elements in COLLECTION.
This function continues until all candidates have been entered or
until the user enters a value of \"\".  Duplicate entries are not
allowed."
  (let* ((format-function (or format-function (lambda (o) (format "%S" o))))
         (collection (if (functionp predicate) (-filter predicate collection) collection))
         (collection (magithub--zip collection format-function nil)))
    (cdr (assoc-string
          (completing-read prompt collection nil require-match
                           (when default (funcall format-function default)))
          collection))))

(defun magithub--completing-read-multiple (prompt collection &optional format-function predicate require-match default)
  "Using PROMPT, get a list of elements in COLLECTION.
This function continues until all candidates have been entered or
until the user enters a value of \"\".  Duplicate entries are not
allowed."
  (let ((this t) (coll (copy-tree collection)) ret)
    (while (and collection this)
      (setq this (magithub--completing-read
                  prompt coll format-function
                  predicate require-match default))
      (when this
        (push this ret)
        (setq coll (delete this coll))))
    ret))

(defconst magithub-hash-regexp
  (rx bow (= 40 (| digit (any (?A . ?F) (?a . ?f)))) eow)
  "Regexp for matching commit hashes.")

(defun magithub-usable-p ()
  "Non-nil if Magithub should do its thing."
  (and (magithub-enabled-p)
       (magithub-github-repository-p)
       (and (or (magithub-offline-p)
                (magithub--api-available-p))
            ;; if we're offline, source-repo will get the cached value
            ;; otherwise, we only want to query the API if it's available
            (magithub-repo))))

(defmacro magithub--deftoggle (name doc on-by-default hook func)
  "Define a section-toggle command."
  (declare (indent defun))
  `(prog1 (defun ,name ()
            ,(concat "Toggle the " doc " section.")
            (interactive)
            (if (memq ,func ,hook)
                (remove-hook ',hook ,func)
              (add-hook ',hook ,func t))
            (magit-refresh)
            (memq ,func ,hook))
     ,(when on-by-default
        `(eval-after-load "magit"
           '(let ((inhibit-magit-refresh t))
              (add-hook ',hook ,func t))))))

(defun magithub--zip-case (p e)
  "Get an appropriate value for element E given property/function P."
  (cond
   ((null p) e)
   ((functionp p) (funcall p e))
   ((symbolp p) (plist-get e p))
   (t nil)))

(defun magithub--zip (object-list prop1 prop2)
  "Process OBJECT-LIST into an alist defined by PROP1 and PROP2.

If a prop is a symbol, that property will be used.

If a prop is a function, it will be called with the
current element of OBJECT-LIST.

If a prop is nil, the entire element is used."
  (delq nil
        (-zip-with
         (lambda (e1 e2)
           (let ((p1 (magithub--zip-case prop1 e1))
                 (p2 (magithub--zip-case prop2 e2)))
             (unless (or (and prop1 (not p1))
                         (and prop2 (not p2)))
               (cons (if prop1 p1 e1)
                     (if prop2 p2 e2)))))
         object-list object-list)))

(defun magithub--satisfies-p (preds obj)
  "Non-nil when all functions in PREDS are non-nil for OBJ."
  (while (and (listp preds)
              (functionp (car preds))
              (funcall (car preds) obj))
    (setq preds (cdr preds)))
  (null preds))

(defun magithub-section-type (section)
  (let* ((type (magit-section-type section))
         (name (symbol-name type)))
    (and (string-prefix-p "magithub-" name)
         (intern (substring name 9)))))

(defvar magithub-thing-type-specializations
  '((user assignee))
  "Alist of general types to specific types.
Specific types offer more relevant functionality to a given
section, but are inconvenient for `magithub-thing-at-point'.
This alist defines equivalencies such that a search for the
general type will also return sections of a specialized type.")

(defun magithub-thing-at-point (type)
  "Determine the thing of TYPE at point.
If TYPE is `all', an alist of types to objects is returned."
  (let ((sec (magit-current-section)))
    (if (eq type 'all)
        (let (all)
          (while sec
            (when-let ((type (magithub-section-type sec)))
              (push (cons type (magit-section-value sec))
                    all))
            (setq sec (magit-section-parent sec)))
          all)
      (while (and sec
                  (not (let ((this-type (magithub-section-type sec)))
                         (or
                          ;; exact match
                          (eq type this-type)
                          ;; equivalency
                          (thread-last magithub-thing-type-specializations
                            (alist-get type)
                            (memq this-type))))))
        (setq sec (magit-section-parent sec)))
      (and sec (magit-section-value sec)))))

(defun magithub-verify-manage-labels (&optional interactive)
  "Verify the user has permission to manage labels.
If the authenticated user does not have permission, an error will
be signaled.

If INTERACTIVE is non-nil, a `user-error' will be raised instead
of a signal (e.g., for interactive forms)."
  (let-alist (magithub-repo)
    (if .permissions.push t
      (if interactive
          (user-error "You're not allowed to manage labels in %s" .full_name)
        (signal 'error `(unauthorized manage-labels ,(progn .full_name)))))))

(defun magithub-bug-reference-mode-on ()
  "In GitHub repositories, configure `bug-reference-mode'."
  (interactive)
  (when (magithub-usable-p)
    (when-let ((repo (magithub-repo)))
      (bug-reference-mode 1)
      (setq-local bug-reference-bug-regexp "#\\(?2:[0-9]+\\)")
      (setq-local bug-reference-url-format
                  (format "%s/issues/%%s" (alist-get 'html_url repo))))))

(defun magithub-filter-all (funcs list)
  "Return LIST without elements that fail any element of FUNCS."
  (dolist (f funcs)
    (setq list (cl-remove-if-not f list)))
  list)

(defvar magithub-preferred-remote-method 'ssh_url
  "Preferred method when cloning or adding remotes.
One of the following:

  `clone_url' (https://github.com/octocat/Hello-World.git)
  `git_url'   (git:github.com/octocat/Hello-World.git)
  `ssh_url'   (git@github.com:octocat/Hello-World.git)")

(defun magithub-repo--clone-url (repo)
  "Get the preferred cloning URL from REPO."
  (alist-get magithub-preferred-remote-method repo))

(defun magithub--wait-for-git (proc &optional seconds)
  "Wait for git process PROC, polling every SECONDS seconds."
  (let ((seconds (or seconds 0.5)))
    (while (process-live-p proc)
      (sit-for seconds))))

(defmacro magithub--run-git-synchronously (&rest body)
  (declare (debug t))
  (let ((valsym (cl-gensym)) final-form)
    (while body
      (let ((form (pop body)))
        (push `(let ((,valsym ,form))
                 (if (processp ,valsym)
                     (magithub--wait-for-git ,valsym)
                   ,valsym))
              final-form)))
    `(progn
       ,@(nreverse final-form))))

(defmacro magithub-interactive-issue-or-pr (sym args doc &rest body)
  "Declare an interactive form that works on both issues and PRs.
SYM is a postfix for the function symbol.  An appropriate prefix
will be added for both the issue-version and PR-version.

ARGS should be a list of one element, the symbol ISSUE-OR-PR.

DOC is a doc-string.

BODY is the function implementation."
  (declare (indent defun)
           (doc-string 3))
  (unless (eq (car args) 'issue-or-pr)
    (error "For clarity, the first argument must be ISSUE-OR-PR"))
  (let* ((snam (symbol-name sym))
         (isym (intern (concat "magithub-issue-" snam)))
         (psym (intern (concat "magithub-pull-request-" snam))))
    `(list
      (defun ,isym ,(cons 'issue (cdr args))
        ,(format (concat doc "\n\nSee also `%S'.") "ISSUE" psym)
        (interactive (list (or (magithub-thing-at-point 'issue)
                               (magithub-issue-completing-read-issues))))
        (let ((issue-or-pr issue))
          ,@body))
      (defun ,psym ,(cons 'pull-request (cdr args))
        ,(format (concat doc "\n\nSee also `%S'.") "PULL-REQUEST" isym)
        (interactive (list (or (magithub-thing-at-point 'pull-request)
                               (magithub-issue-completing-read-pull-requests))))
        (let ((issue-or-pr pull-request))
          ,@body)))))

(defun magithub-core-bucket (collection key-func &optional value-func)
  "Bucket COLLECTION by ENTRY-FUNC and VALUE-FUNC.

Each element of COLLECTION is passed through KEY-FUNC to
determine its key in an alist.  If specified, the value is
determined by VALUE-FUNC.

Returns an alist of these keys to lists of values.

See also `magithub-fnnor-each-bucket'."
  (unless value-func
    (setq value-func #'identity))
  (let (bucketed)
    (dolist (item collection)
      (let ((entry (funcall key-func item))
            (val (funcall value-func item)))
        (if-let (bucket (assoc entry bucketed))
            (push val (cdr bucket))
          (push (cons entry (list val))
                bucketed))))
    bucketed))

(defmacro magithub-core-bucket-multi (collection &rest buckets)
  "Chain calls to `magithub-core-bucket'."
  (declare (indent 1))
  (let* ((fnelsym (cl-gensym))
         (apply-to fnelsym)
         form)
    (while buckets
      (setq form `(magithub-core-bucket
                   ,(or form collection)
                   (lambda (,fnelsym) (funcall ,(pop buckets) ,apply-to)))
            apply-to `(car ,apply-to)))
    form))

(defmacro magithub-for-each-bucket (buckets key values &rest body)
  "Do things for each bucket in BUCKETS.

For each bucket in BUCKETs, bind the key to KEY and its
contents (a list) to VALUES and execute BODY.

See also `magithub-core-bucket'."
  (declare (indent 3) (debug t))
  (let ((buckets-sym (cl-gensym)))
    `(let ((,buckets-sym ,buckets))
       (while ,buckets-sym
         (-let (((,key . ,values) (pop ,buckets-sym)))
           ,@body)))))

(defun magithub-core-color-completing-read (prompt)
  "Generic completing-read for a color."
  (let* ((colors (list-colors-duplicates))
         (len (apply #'max (mapcar (lambda (c) (length (car c))) colors)))
         (sample (make-string 20 ?\ )))
    (car
     (magithub--completing-read
      prompt colors
      (lambda (colors)
        (format (format "%%-%ds  %%s" len) (car colors)
                (propertize sample 'face `(:background ,(car colors)))))))))

(defun magit-section-show-level-5 ()
  "Show surrounding sections up to fifth level."
  (interactive)
  (magit-section-show-level 5))

(defun magit-section-show-level-5-all ()
  "Show all sections up to fifth level."
  (interactive)
  (magit-section-show-level -5))

(defun magithub-refresh ()
  (interactive (user-error "This is no longer an interactive function; use C-u magit-refresh instead :-)"))
  (when (and current-prefix-arg
             (magithub-usable-p)
             (y-or-n-p "Refresh GitHub data? ")
             (or (magithub--api-available-p)
                 (y-or-n-p "GitHub doesn't seem to responding, are you sure? ")))
    (magithub-cache-invalidate)))

(eval-after-load "magit"
  '(progn
     (dolist (hook '(magit-revision-mode-hook git-commit-setup-hook))
       (add-hook hook #'magithub-bug-reference-mode-on))
     (add-hook 'magit-pre-refresh-hook #'magithub-refresh)))

(provide 'magithub-core)
;;; magithub-core.el ends here
