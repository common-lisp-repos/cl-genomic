;;;
;;; Copyright (C) 2007-2008, Keith James. All rights reserved.
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;;

(in-package :bio-sequence)

;;; Default methods which ignore all data from the parser
(defmethod begin-object ((parser bio-sequence-parser))
  nil)

(defmethod object-alphabet ((parser bio-sequence-parser)
                            alphabet)
  nil)

(defmethod object-relation ((parser bio-sequence-parser)
                            relation value)
  nil)

(defmethod object-identity ((parser bio-sequence-parser)
                            identity)
  nil)

(defmethod object-description ((parser bio-sequence-parser)
                               description)
  nil)

(defmethod object-residues ((parser bio-sequence-parser)
                            residues)
  nil)

(defmethod object-quality ((parser bio-sequence-parser)
                           quality)
  nil)

(defmethod end-object ((parser bio-sequence-parser))
  nil)

;;; Collecting raw data into Lisp objects
(defmethod begin-object ((parser raw-sequence-parser))
  (with-slots (raw) parser
    (setf raw '())))

(defmethod object-alphabet ((parser raw-sequence-parser)
                            alphabet)
  (with-slots (raw) parser
    (setf raw (acons :alphabet alphabet raw))))

(defmethod object-identity ((parser raw-sequence-parser)
                            (identity string))
  (with-slots (raw) parser
    (setf raw (acons :identity identity raw))))

(defmethod object-description ((parser raw-sequence-parser)
                               (description string))
  (with-slots (raw) parser
    (setf raw (acons :description description raw))))

(defmethod object-residues ((parser raw-sequence-parser)
                            (residues string))
  (with-slots (raw) parser
    (let ((vec (assocdr :residues raw))) 
      (if vec
          (vector-push-extend residues vec)
        (setf raw (acons :residues
                         (make-array 1 :adjustable t :fill-pointer t
                                     :initial-element residues) raw))))))

(defmethod object-quality ((parser raw-sequence-parser)
                           (quality string))
  (with-slots (raw) parser
    (let ((vec (assocdr :quality raw))) 
      (if vec
          (vector-push-extend quality vec)
        (setf raw (acons :quality
                         (make-array 1 :adjustable t :fill-pointer t
                                     :initial-element quality) raw))))))

(defmethod end-object ((parser raw-sequence-parser))
  (with-slots (raw) parser
    (dolist (key '(:residues :quality))
      (let ((val (assocdr key raw)))
        (when (and val (not (stringp val)))
          (setf (assocdr key raw) (concat-strings val)))))
    raw))


;;; Collecting data into CLOS instances
(defmethod begin-object ((parser simple-sequence-parser))
  (with-slots (identity description residues) parser
      (setf identity nil
            description nil
            residues (make-array 0 :adjustable t :fill-pointer 0))))

(defmethod object-alphabet ((parser simple-sequence-parser)
                            alphabet)
  (setf (parsed-alphabet parser) alphabet))

(defmethod object-identity ((parser simple-sequence-parser)
                            (identity string))
  (setf (parsed-identity parser) identity))

(defmethod object-description ((parser simple-sequence-parser)
                               (description string))
  (setf (parsed-description parser) description))

(defmethod object-residues ((parser simple-sequence-parser)
                            (residues vector))
  (vector-push-extend residues (parsed-residues parser)))

(defmethod end-object ((parser simple-sequence-parser))
  (make-bio-sequence parser))

;;; Collecting data into CLOS instances with quality
(defmethod begin-object ((parser quality-sequence-parser))
  (with-slots (quality) parser
      (setf quality (make-array 0 :adjustable t :fill-pointer 0)))
  (call-next-method))

(defmethod object-quality ((parser quality-sequence-parser)
                           (quality vector))
  (vector-push-extend quality (parsed-quality parser)))


;;; Collecting data into CLOS instances without explicit residues
(defmethod begin-object ((parser virtual-sequence-parser))
  (with-slots (length) parser
      (setf length 0))
  (call-next-method))

(defmethod object-residues ((parser virtual-sequence-parser)
                            (residues vector))
  (incf (parsed-length parser) (length residues)))

;;; CLOS instance constructors
(defmethod make-bio-sequence ((parser simple-sequence-parser))
  (let ((class (ecase (parsed-alphabet parser)
                 (:dna 'dna-sequence)
                 (:rna 'rna-sequence)))
        (chunks (parsed-residues parser)))
    (when (zerop (length chunks))
      (error 'invalid-operation-error
             :text "attempt to make an empty concrete bio-sequence"))
    (let ((residues (etypecase (aref chunks 0)
                      (string (concat-strings chunks))
                      ((array (unsigned-byte 8))
                       (concat-into-sb-string chunks)))))
      (make-instance class
                     :identity (parsed-identity parser)
                     ;; FIXME -- :description
                     :residues residues))))

(defmethod make-bio-sequence ((parser virtual-sequence-parser))
  (let ((class (ecase (parsed-alphabet parser)
                 (:dna 'dna-sequence)
                 (:rna 'rna-sequence))))
    (make-instance class
                   :identity (parsed-identity parser)
                   ;; FIXME -- :description
                   :length (parsed-length parser))))

(defmethod make-bio-sequence ((parser quality-sequence-parser))
  (let ((class (ecase (parsed-alphabet parser)
                 (:dna 'dna-quality-sequence)))
        (residue-chunks (parsed-residues parser))
        (quality-chunks (parsed-quality parser)))
    (when (zerop (length residue-chunks))
      (error 'invalid-operation-error
             :text "no sequence residue data provided"))
    (when (zerop (length quality-chunks))
      (error 'invalid-operation-error
             :text "no quality data provided"))
    ;; FIXME -- On sbcl with-output-to-string is apparently very fast
    ;; for this sort of operation. Maybe faster than pre-allocating a
    ;; string and copying into it?
    (let ((residues (etypecase (aref residue-chunks 0)
                      (string (concat-strings residue-chunks))
                      ((array (unsigned-byte 8))
                       (concat-into-sb-string residue-chunks))))
          (quality (if (= 1 (length quality-chunks))
                       (aref quality-chunks 0)
                     (concat-quality-arrays quality-chunks))))
      (make-instance class
                     :identity (parsed-identity parser)
                     ;; FIXME -- :description
                     :residues residues
                     :quality quality
                     :metric (parsed-metric parser)))))

(defun split-sequence-stream (stream writer n generator)
  "Reads sequence records from STREAM and uses function WRITER to
write N records each to new files whose pathnames are created by
function GENERATOR."
  (loop
     with in = (make-line-input-stream stream)
     as num-written = (funcall writer in n (funcall generator))
     until (zerop num-written)))

(defun write-n-raw-sequences (generator writer n pathname)
  "Reads up to N raw sequence records by calling closure GENERATOR and
writes them into a new file of PATHNAME. Returns the number of records
actually written, which may be 0 if STREAM contained no further
records. WRITER is a function capable of writing an alist of raw data
contain keys and values as created by {defclass raw-sequence-parser} ,
for example, {defun write-raw-fasta} and {defun write-raw-fastq} ."
  (declare (optimize (speed 3)))
  (declare (type function writer))
  (let ((num-written
         (with-open-file (out pathname :direction :output
                          :if-exists :supersede
                          :element-type 'base-char
                          :external-format :ascii)
           (loop
              for count of-type fixnum from 0 below n
              ;; for raw = (next generator) then (next generator)
              as raw = (next generator)
              while raw
              do (funcall writer raw out)
              finally (return count)))))
  (when (zerop num-written)
    (delete-file pathname))
  num-written))

