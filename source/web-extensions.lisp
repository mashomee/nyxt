;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(uiop:define-package :nyxt/web-extensions
  (:use :common-lisp :nyxt)
  (:import-from #:class-star #:define-class)
  (:import-from #:serapeum #:export-always)
  (:documentation "WebExtensions API conformance code."))
(in-package :nyxt/web-extensions)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (trivial-package-local-nicknames:add-package-local-nickname :alex :alexandria)
  (trivial-package-local-nicknames:add-package-local-nickname :sera :serapeum)
  (trivial-package-local-nicknames:add-package-local-nickname :hooks :serapeum/contrib/hooks))

(defun load-js-file (file buffer mode)
  "Load JavaScript code from a file into the BUFFER."
  (ffi-buffer-evaluate-javascript
   buffer (uiop:read-file-string (merge-extension-path mode file)) (name mode)))

(defun load-css-file (file buffer mode)
  "Load CSS from the FILE and inject it into the BUFFER document."
  (nyxt::html-set-style
   (uiop:read-file-string (merge-extension-path mode file)) buffer))

(defun make-activate-content-scripts-handler (mode name)
  (nyxt::make-handler-buffer
   (lambda (buffer)
     (dolist (script (content-scripts mode))
       (when (funcall (matching-filter script) (render-url (url buffer)))
         (dolist (js-file (js-files script))
           (load-js-file js-file buffer mode))
         (dolist (css-file (css-files script))
           (load-css-file css-file buffer mode)))
       url))
   :name name))

(define-class content-script ()
  ((matching-filter (error "Matching filter is required.")
                    :type function
                    :documentation "When to activate the content script.
A function that takes a URL designator and returns t if it needs to be activated
for a given URL, and nil otherwise")
   (js-files nil
             :type list
             :documentation "JavaScript files to load.")
   (css-files nil
              :type list
              :documentation "Stylesheets to load."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(defun make-content-script (&key (matches (error "Matches key is mandatory.")) js css)
  ;; TODO: Replace "/*" with ".*"? Requires regexps and some smartness, though.
  (let ((sanitize-mozilla-regex (alex:curry #'str:replace-using '("*." "*"
                                                                  "*" ".*"
                                                                  "?" ".?"))))
    (make-instance
     'content-script
     :matching-filter (apply #'match-regex
                             (mapcar sanitize-mozilla-regex (uiop:ensure-list matches)))
     :js-files (uiop:ensure-list js)
     :css-files (uiop:ensure-list css))))

(defun read-file-as-base64 (file)
  (let ((arr (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
    (with-open-file (s file :element-type '(unsigned-byte 8))
      (loop for byte = (read-byte s nil nil)
            while byte
            do (vector-push-extend byte arr)
            finally (return (base64:usb8-array-to-base64-string arr))))))

(defun default-browser-action-icon (json optimal-height)
  (let* ((browser-action (alex:assoc-value json :browser--action))
         (default-icon (alex:assoc-value browser-action :default--icon)))
    (if (stringp default-icon)
        default-icon
        (rest (first (sort (append (alex:assoc-value browser-action :default--icon)
                                   (alex:assoc-value json :icons))
                           (lambda (a b)
                             (< (abs (- optimal-height a))
                                (abs (- optimal-height b))))
                           :key (alex:compose #'parse-integer #'symbol-name #'first)))))))

(defun encode-browser-action-icon (json extension-directory)
  (let* ((status-buffer-height (nyxt:height (status-buffer (current-window))))
         (padded-height (- status-buffer-height 10))
         (best-icon
           (default-browser-action-icon json padded-height)))
    (format nil "<img src=\"data:image/png;base64,~a\" alt=\"~a\"
height=~a/>"
            (read-file-as-base64 (uiop:merge-pathnames* best-icon extension-directory))
            (alex:assoc-value json :name)
            padded-height)))

(defun make-browser-action (json)
  (let* ((browser-action (alex:assoc-value json :browser--action))
         (sorted-icons (sort (alex:assoc-value browser-action :theme--icons)
                             #'> :key (alex:rcurry #'alex:assoc-value :size)))
         (max-icon (first sorted-icons))
         (default-icon (default-browser-action-icon json 1000)))
    (make-instance 'browser-action
                   :default-popup (alex:assoc-value browser-action :default--popup)
                   :default-title (alex:assoc-value browser-action :default--title)
                   :default-icon default-icon
                   :default-dark-icon (or (alex:assoc-value max-icon :dark)
                                          (alex:assoc-value max-icon :light))
                   :default-light-icon (or (alex:assoc-value max-icon :light)
                                           (alex:assoc-value max-icon :dark)))))

(define-class browser-action ()
  ((default-popup nil
                  :type (or null string pathname)
                  :documentation "An HTML file for the popup to open when its icon is clicked.")
   (default-title nil
                  :type (or null string)
                  :documentation "The title to call the popup with.")
   (default-icon nil
                 :type (or null string)
                 :documentation "The extension icon to use in mode line.")
   (default-light-icon nil
                       :type (or null string)
                       :documentation "The extension icon for use in mode line in the light theme.")
   (default-dark-icon nil
                       :type (or null string)
                       :documentation "The extension icon for use in mode line in the dark theme."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(define-mode extension ()
  "The base mode for any extension to inherit from."
  ((name (error "Extension should have a name")
         :type string)
   (version (error "Extension should have a version")
            :type string)
   (manifest nil
             :type (or null string)
             :documentation "Original contents of the manifest.json file.")
   (id nil
       :type (or null string)
       :documentation "A unique ID of the extension.
Is shared between all the instances of the same extension.")
   (background-buffer nil
                      :documentation "The buffer to host background page of the extension in.
Is shared between all the instances of the same extension.")
   (description nil
                :type (or null string))
   (homepage-url nil
                 :type (or null quri:uri))
   (extension-directory nil
              :type (or null pathname)
              :documentation "The directory that the extension resides in.")
   (permissions nil
                :type list-of-strings
                :documentation "List of API permissions extension requires.")
   (content-scripts nil
                    :type list
                    :documentation "A list of `content-script's used by this extension.")
   (browser-action nil
                   :type (or null browser-action)
                   :documentation "Configuration for popup opening on extension icon click.")
   (handler-names nil
                  :type list)
   (destructor (lambda (mode)
                 (loop for name in (handler-names mode)
                       for hook in (list (buffer-loaded-hook (buffer mode)))
                       do (hooks:remove-hook hook name))
                 ;; Destroy the view when there are no more instances of this extension.
                 (when (null (sera:filter (alex:rcurry #'typep (type-of mode))
                                          (alex:mappend #'modes (buffer-list))))
                   (nyxt::buffer-delete (background-buffer mode)))))
   (constructor (lambda (mode)
                  (let ((content-script-name (gensym)))
                    (hooks:add-hook (buffer-loaded-hook (buffer mode))
                                    (make-activate-content-scripts-handler mode content-script-name))
                    (push content-script-name (handler-names mode))
                    (unless (background-buffer mode)
                      ;; Need to set it to something to not trigger this in other instances.
                      (setf (background-buffer mode) t)
                      (setf (background-buffer mode) (make-background-buffer))))))))

(export-always 'has-permission-p)
(defmethod has-permission-p ((extension extension) (permission string))
  (str:s-member permission (permissions extension)))

(export-always 'merge-extension-path)
(defmethod merge-extension-path ((extension extension) path)
  (uiop:merge-pathnames* path (extension-directory extension)))

(defmethod nyxt::format-mode ((extension extension))
  (name extension))

(defun open-popup (extension-class &optional (buffer (current-buffer)))
  (with-current-buffer buffer
    ;;TODO: Send click message to background script if there's no popup.
    (sera:and-let* ((extension (nyxt:find-submode (nyxt:current-buffer) extension-class))
                    (browser-action (browser-action extension))
                    (default-popup (default-popup browser-action))
                    (popup (make-instance 'user-panel-buffer
                                          :title (default-title (browser-action extension)))))
      (nyxt::window-add-panel-buffer
       (current-window) popup
       :right)
      (buffer-load (quri.uri.file:make-uri-file :path (merge-extension-path extension default-popup))
                   :buffer popup))))

(export-always 'load-web-extension)
(defmacro load-web-extension (lispy-name directory)
  "Make an extension from DIRECTORY accessible as Nyxt mode (under LISPY-NAME).
DIRECTORY should be the one containing manifest.json file for the extension in question."
  (let* ((directory (uiop:parse-native-namestring directory))
         (manifest-text (uiop:read-file-string (uiop:merge-pathnames* "manifest.json" directory)))
         (json (json:decode-json-from-string manifest-text)))
    `(progn
       (define-mode ,lispy-name (extension)
         ,(alex:assoc-value json :description)
         ((name ,(alex:assoc-value json :name))
          (version ,(alex:assoc-value json :version))
          (manifest ,manifest-text)
          (id (or (symbol-name (gensym ,(alex:assoc-value json :name))))
              :allocation :class)
          (background-buffer nil
                             :allocation :class)
          (description ,(alex:assoc-value json :description))
          (extension-directory ,directory)
          (homepage-url ,(alex:assoc-value json :homepage--url))
          (browser-action ,(make-browser-action json))
          (content-scripts (list ,@(mapcar (lambda (content-script-alist)
                                             (apply #'make-content-script
                                                    (alex:alist-plist content-script-alist)))
                                           (alex:assoc-value json :content--scripts))))))
       (defmethod initialize-instance :after ((extension ,lispy-name) &key)
         (setf (nyxt:glyph extension)
               (spinneret:with-html-string
                 (:a :class "button" :href (lisp-url `(open-popup ',(mode-name extension)))
                     :title (format nil "Open the browser action of ~a" (mode-name extension))
                     (:raw (setf (default-icon (browser-action extension))
                                 (encode-browser-action-icon (quote ,json) ,directory))))))))))
