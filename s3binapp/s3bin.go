package main

import (
	"bytes"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"path"
	"strings"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
	"github.com/buaazp/fasthttprouter"
	"github.com/google/uuid"
	"github.com/jamiealquiza/envy"
	"github.com/valyala/fasthttp"
)

// THIS TOOL IS NOT SECURE AND SHOULD NOT BE USED PUBLIC OR IN PRODUCTION
// its just a stupid copy to s3 service

// from: https://github.com/buaazp/fasthttprouter/blob/master/examples/auth/auth.go

// basicAuth returns the username and password provided in the request's
// Authorization header, if the request uses HTTP Basic Authentication.
// See RFC 2617, Section 2.
func basicAuth(ctx *fasthttp.RequestCtx) (username, password string, ok bool) {
	auth := ctx.Request.Header.Peek("Authorization")
	if auth == nil {
		return
	}
	return parseBasicAuth(string(auth))
}

// parseBasicAuth parses an HTTP Basic Authentication string.
// "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==" returns ("Aladdin", "open sesame", true).
func parseBasicAuth(auth string) (username, password string, ok bool) {
	const prefix = "Basic "
	if !strings.HasPrefix(auth, prefix) {
		return
	}
	c, err := base64.StdEncoding.DecodeString(auth[len(prefix):])
	if err != nil {
		return
	}
	cs := string(c)
	s := strings.IndexByte(cs, ':')
	if s < 0 {
		return
	}
	return cs[:s], cs[s+1:], true
}

// BasicAuth is the basic auth handler
func BasicAuth(h fasthttp.RequestHandler, requiredUser, requiredPassword string) fasthttp.RequestHandler {
	return fasthttp.RequestHandler(func(ctx *fasthttp.RequestCtx) {
		// Get the Basic Authentication credentials
		user, password, hasAuth := basicAuth(ctx)

		if hasAuth && user == requiredUser && password == requiredPassword {
			// Delegate request to the given handle
			h(ctx)
			return
		}
		// Request Basic Authentication otherwise
		ctx.Error(fasthttp.StatusMessage(fasthttp.StatusUnauthorized), fasthttp.StatusUnauthorized)
		ctx.Response.Header.Set("WWW-Authenticate", "Basic realm=Restricted")
	})
}

func ping(sess *session.Session, bucketName, basePath string) fasthttp.RequestHandler {
	return fasthttp.RequestHandler(func(ctx *fasthttp.RequestCtx) {
		s3Client := s3.New(sess)
		input := &s3.ListObjectsInput{
			Bucket: aws.String(bucketName),
		}
		_, err := s3Client.ListObjects(input)
		if err != nil {
			fmt.Printf("Error accessing bucket - %v\n", err)
			ctx.Error("Error accessing Bucket", 400)
			return
		}
		fmt.Fprint(ctx, "Pong!\n")
	})
}

func genID() string {
	return uuid.New().String()
}

func postBin(sess *session.Session, bucketName, basePath string) fasthttp.RequestHandler {
	return fasthttp.RequestHandler(func(ctx *fasthttp.RequestCtx) {
		binID := genID()

		body := ctx.PostBody()
		contentType := "text/plain"

		s3Client := s3.New(sess)
		input := s3.PutObjectInput{
			Bucket:             aws.String(bucketName),
			Key:                aws.String(path.Join(basePath, binID)),
			ACL:                aws.String("private"),
			Body:               bytes.NewReader(body),
			ContentLength:      aws.Int64(int64(len(body))),
			ContentType:        aws.String(contentType),
			ContentDisposition: aws.String("attachment"),
		}
		_, err := s3Client.PutObject(&input)

		if err != nil {
			if aerr, ok := err.(awserr.Error); ok {
				switch aerr.Code() {
				case s3.ErrCodeNoSuchBucket:
					fmt.Printf("bucket %s does not exist - %v\n", bucketName, err)

				}
				fmt.Printf("could not upload %v\n", err)
				ctx.Error("could not upload", 500)
			}
			return
		}

		fmt.Fprintf(ctx, "BinID %s\n", binID)
	})
}

func main() {
	sess := session.Must(session.NewSessionWithOptions(session.Options{
		SharedConfigState: session.SharedConfigEnable,
	}))

	if sess.Config.Region == nil {
		sess.Config.WithRegion("us-east-1")
	}

	port := flag.String("port", "8000", "Port the app binds to")
	user := flag.String("user", "foo", "Basic auth user")
	pass := flag.String("pass", "bar", "Basic auth password")
	bucketName := flag.String("bucket", "dcos-secure-instance-profiles-app", "Name of the bucket to be used")
	basePath := flag.String("path", "/bin", "Base path / prefix being used")

	envy.Parse("BINAPP")

	router := fasthttprouter.New()
	router.GET("/ping", ping(sess, *bucketName, *basePath))
	router.POST("/bin", BasicAuth(postBin(sess, *bucketName, *basePath), *user, *pass))

	log.Fatal(fasthttp.ListenAndServe(fmt.Sprintf(":%s", *port), router.Handler))
}
