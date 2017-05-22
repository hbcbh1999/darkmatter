(in-package :cl-user)
(defpackage darkmatter
  (:use :cl :websocket-driver)
  (:import-from :lack.builder
                :builder)
  (:import-from :djula
                :add-template-directory
                :compile-template*
                :render-template*)
  (:import-from :string-case
                :string-case)
  (:import-from :alexandria
                :if-let
                :read-file-into-string
                :starts-with-subseq)
  (:export *eval-server*))
(in-package :darkmatter)

(defparameter *root-directory*
  (asdf:system-relative-pathname "darkmatter" ""))

(defparameter *static-directory*
  (asdf:system-relative-pathname "darkmatter" "static/"))

(djula:add-template-directory (asdf:system-relative-pathname "darkmatter" "templates/"))
(defparameter +base.html+ (djula:compile-template* "base.html"))

(defpackage darkmatter.plot
  (:use :cl)
  (:export scatter
           make-scatter))
(in-package :darkmatter.plot)
(defstruct scatter
  (xlabel "x" :type string)
  (ylabel "y" :type string)
  (data #() :type array))
(in-package darkmatter)

(defpackage darkmatter.local
  (:use :cl)
  (:export *last-package*))
(in-package :darkmatter.local)
(defparameter *last-package* (package-name *package*))
(in-package :darkmatter)

(defun eval-string (src)
  (format t "Come: ~A~%" src)
  (eval `(in-package ,darkmatter.local:*last-package*))
  (let* ((*standard-output* (make-string-output-stream))
         (*error-output* (make-string-output-stream))
         (eo "")
         (sexp nil)
         (return-value nil)
         (pos 0))
    (handler-case
      (loop while pos
            do (multiple-value-setq (sexp pos)
                 (read-from-string src :eof-error-p t :start pos))
               (setf return-value (eval sexp)))
      (END-OF-FILE (c) nil)
      (error (c) (format t "<pre>~A</pre>" c)))
    (setf eo (get-output-stream-string *error-output*))
    (setf darkmatter.local:*last-package* (package-name *package*))
    (in-package :darkmatter)
    (jsown:to-json
      `(:obj ("return" . ,(format nil "~A" return-value))
             ("output" . ,(format nil "~A~A"
                            (if (string= "" eo)
                                ""
                                (format nil "<pre>~A</pre>" eo))
                            (string-left-trim '(#\Space #\Newline)
                              (get-output-stream-string *standard-output*))))))))

(defun save-file (fname src)
  (with-open-file (out fname :direction :output :if-exists :supersede)
    (format out "~A" src))
  (jsown:to-json
    `(:obj ("return" . ,(format nil "~A" fname)))))

(defun read-file (env path)
  (let ((mime (get-mime-type path)))
    (with-open-file (stream path :direction :input :if-does-not-exist nil)
      `(200 (:content-type ,(gethash "content-type" (getf env :headers))
             :content-length ,(file-length stream))
      (,path)))))

(defun serve-index ()
  `(200 (:content-type "text/html")
    (,(read-file-into-string (merge-pathnames *static-directory* "index.html")))))

(defun read-global-file (env path)
  (get-editable-file path env))

(defun get-editable-file (path env)
  `(200 (:content-type "text/html")
    (,(render-template* +base.html+ nil
                    :host (getf env :server-name)
                    :port (getf env :server-port)
                    :path path))))

(defun notfound (env)
  `(404 (:content-type "text/plain") ("404 Not Found")))

(defun websocket-p (env)
  (string= "websocket" (gethash "upgrade" (getf env :headers))))

(defparameter *websocket-binder*
  (lambda (app bind)
    (lambda (env)
      (if (websocket-p env)
        (funcall bind env)
        (funcall app env))))
  "Middleware for binding websocket message")

(defun bind-message (env)
  "Bind websocket messages"
  (let ((ws (make-server env)))
    (on :message ws
        (lambda (message)
          (let* ((json (jsown:parse message))
                 (message (jsown:val json "message"))
                 (res (string-case
                        (message)
                        ("eval" (eval-string (jsown:val json "data")))
                        ("save" (save-file (jsown:val json "file")
                                           (jsown:val json "data")))
                        (t "{}"))))
            (send ws res))))
    (lambda (responder)
      (declare (ignore responder))
      (start-connection ws))))

(defparameter *eval-server*
  (lambda (env)
    (let ((uri (getf env :request-uri)))
      (if (string= "/" uri)
        (serve-index)
        (let ((path (subseq uri 1)))
          (if-let (data (read-global-file env path))
                  data
                  (if (string= "LISP" (string-upcase (pathname-type path)))
                    (get-editable-file path env)
                    (notfound env)))))))
  "File server")

(setf *eval-server*
(builder
  (:static :path (lambda (path)
                   (if (or (starts-with-subseq "/static/" path)
                           (starts-with-subseq "/bower_components/" path))
                     path
                     nil))
           :root *root-directory*)
  *eval-server*))

(setf *eval-server*
      (funcall *websocket-binder* *eval-server* #'bind-message))

